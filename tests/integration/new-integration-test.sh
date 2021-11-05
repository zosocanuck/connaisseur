set -eo pipefail

# This script is expected to be called from the root folder of Connaisseur
declare -A DEPLOYMENT_VALIDITY=(["VALID"]="0" ["INVALID"]="0")
RED="\033[0;31m"
GREEN="\033[0;32m"
NC="\033[0m"
SUCCESS="${GREEN}SUCCESS${NC}"
FAILED="${RED}FAILED${NC}"
EXIT="0"

### SINGLE TEST CASE ####################################
single_test() {  # ID TXT TYP IMG NS OUT VAL
    echo -n "[$1] $2"
    if [[ "$3" == "deploy" ]]; then
        kubectl run pod-$1 --image="$4" --namespace="$5" >output.log 2>&1 || true
    else
        kubectl apply -f $4 >output.log 2>&1 || true
    fi
    if [[ ! "$(cat output.log)" =~ "$6" ]]; then
        echo -e ${FAILED}
        echo "::group::Output"
        cat output.log
        kubectl logs -n connaisseur -lapp.kubernetes.io/instance=connaisseur
        echo "::endgroup::"
        EXIT="1"
    else
        echo -e "${SUCCESS}"
    fi

    if [[ $7 != "null" ]]; then
      DEPLOYMENT_VALIDITY[$7]=$((${DEPLOYMENT_VALIDITY[$7]}+1))
    fi
}

### MULTI TEST CASE FROM FILE ####################################
multi_test() {
  test_cases=$(yq e -o=json".test_cases.$1" tests/integration/cases.yaml)
  len=$(echo ${test_cases} | jq 'length')
    for i in $(seq 0 $(($len-1)))
    do
        test_case=$(echo ${test_cases} | jq ".[$i]")
        ID=$(echo ${test_case} | jq -r ".id")
        TEST_CASE_TXT=$(echo ${test_case} | jq -r ".txt")
        TYPE=$(echo ${test_case} | jq -r ".type")
        REF=$(echo ${test_case} | jq -r ".ref")
        NAMESPACE=$(echo ${test_case} | jq -r ".namespace")
        MSG=$(echo ${test_case} | jq -r ".msg")
        VALIDITY=$(echo ${test_case} | jq -r ".validity")
        single_test "${ID}" "${TEST_CASE_TXT}" "${TYPE}" "${REF}" "${NAMESPACE}" "${MSG}" "${VALIDITY}"
    done
}

### INSTALLING CONNAISSEUR ####################################
install() {
  echo -n "Installing Connaisseur..."
  make install > /dev/null || { echo "${FAILED}"; exit 1; }
  echo -e "${SUCCESS}"
}

install_helm() {
  echo -n "Installing Connaisseur..."
  helm install connaisseur helm --atomic --create-namespace \
    --namespace connaisseur > /dev/null || { echo "${FAILED}"; exit 1; }
  echo -e "${SUCCESS}"
}

### UPGRADING CONNAISSEUR ####################################
upgrade() {
  echo -n 'Upgrading Connaisseur...'
  make upgrade > /dev/null || { echo -e ${FAILED}; exit 1; }
  echo -e "${SUCCESS}"
}

upgrade_helm() {
  echo -n 'Upgrading Connaisseur...'
  helm upgrade connaisseur helm  -n $(NAMESPACE) --wait > /dev/null || { echo -e ${FAILED}; exit 1; }
  echo -e "${SUCCESS}"
}

### UNINSTALING CONNAISSEUR ####################################
uninstall() {
  echo -n 'Uninstalling Connaisseur...'
  make uninstall > /dev/null || { echo -e "${FAILED}"; exit 1; }
  echo -e "${SUCCESS}"
}

uninstall_helm() {
  echo -n 'Uninstalling Connaisseur...'
  helm uninstall connaisseur -n $(NAMESPACE) && \
    kubectl delete ns $(NAMESPACE) > /dev/null || { echo -e "${FAILED}"; exit 1; }
  echo -e "${SUCCESS}"
}

update_values() {
  for update in "$@"
  do
    yq e -i "${update}" helm/values.yaml
  done
}

debug_vaules() {
  echo "::group::values.yaml"
  cat helm/values.yaml
  echo "::endgroup::"
}


### RUN REGULAR INTEGRATION TEST ####################################
regular_int_test() {
  multi_test "regular"

  ### EDGE CASE TAG IN RELEASES AND TARGETS ####################################
  echo -n "[edge1] Testing edge case of tag defined in both targets and release json file..."
  DEPLOYED_SHA=$(kubectl get pod pod-rs -o yaml | yq e '.spec.containers[0].image' - | sed 's/.*sha256://')
  if [[ "${DEPLOYED_SHA}" != 'c5327b291d702719a26c6cf8cc93f72e7902df46547106a9930feda2c002a4a7' ]]; then
    echo -e "${FAILED}"
  else
    echo -e "${SUCCESS}"
  fi
  N=$(($N+1))

  ### ALERTING TEST ####################################
  echo -n "Checking whether alert endpoints have been called successfully..."
  ENDPOINT_HITS="$(curl -s ${ALERTING_ENDPOINT_IP}:56243 --header 'Content-Type: application/json')"
  NUMBER_OF_DEPLOYMENTS=$((${DEPLOYMENT_VALIDITY["VALID"]}+${DEPLOYMENT_VALIDITY["INVALID"]}))
  EXPECTED_ENDPOINT_HITS=$(jq -n \
  --argjson REQUESTS_TO_SLACK_ENDPOINT ${NUMBER_OF_DEPLOYMENTS} \
  --argjson REQUESTS_TO_OPSGENIE_ENDPOINT  ${DEPLOYMENT_VALIDITY["VALID"]} \
  --argjson REQUESTS_TO_KEYBASE_ENDPOINT ${DEPLOYMENT_VALIDITY["INVALID"]} \
  '{
  "successful_requests_to_slack_endpoint":$REQUESTS_TO_SLACK_ENDPOINT,
  "successful_requests_to_opsgenie_endpoint": $REQUESTS_TO_OPSGENIE_ENDPOINT,
  "successful_requests_to_keybase_endpoint": $REQUESTS_TO_KEYBASE_ENDPOINT
  }')
  diff <(echo "$ENDPOINT_HITS" | jq -S .) <(echo "$EXPECTED_ENDPOINT_HITS" | jq -S .) >diff.log 2>&1 || true
  if [[ -s diff.log ]]; then
    echo -e "${FAILED}"
    echo "::group::Alerting endpoint diff:"
    cat diff.log
    echo "::endgroup::"
    EXIT="1"
  else
    echo -e "${SUCCESS}"
  fi
}


### COSIGN TEST ####################################
cosign_int_test() {
  multi_test "cosign"
}


### NAMESPACE VALIDATION TEST ####################################
namespace_val_int_test() {
  echo -n "Creating namespaces..."
  kubectl create namespace ignoredns > /dev/null
  kubectl label ns ignoredns securesystemsengineering.connaisseur/webhook=ignore > /dev/null
  kubectl create namespace validatedns > /dev/null
  kubectl label ns validatedns securesystemsengineering.connaisseur/webhook=validate > /dev/null
  echo -e "${SUCCESS}"

  multi_test "ignore-namespace-val"
  update_values '.namespacedValidation.mode="validate"'
  upgrade
  multi_test "validate-namespace-val"
}


### DEPLOYMENT TEST ####################################
deployment_int_test() {
  multi_test "deployment"
}


case $1 in
  "regular")
    install
    regular_int_test
    uninstall
    ;;
  "cosign")
    install
    cosign_int_test
    uninstall
    ;;
  "namespace-val")
    update_values '.namespacedValidation.enabled=true'
    install
    namespace_val_int_test
    uninstall
    ;;
  "deployment")
    update_values '.policy += {"pattern": "docker.io/library/*:*", "validator": "dockerhub-basics", "with": {"trust_root": "docker-official"}}' 
    install
    deployment_int_test
    uninstall
    ;;
  "all")
    install
    regular_int_test
    cosign_int_test
    update_values '.namespacedValidation.enabled=true'
    upgrade
    namespace_val_int_test
    update_values '.namespacedValidation.enabled=false' '.policy += {"pattern": "docker.io/library/*:*", "validator": "dockerhub-basics", "with": {"trust_root": "docker-official"}}'
    upgrade
    deployment_int_test
    uninstall
    ;;
  *)
    EXIT="1"
    ;;
esac

if [[ $EXIT == "1" ]]; then
  exit 1
fi
#
# Targets to deploy the operator and Kiali in a remote cluster.
#

.ensure-operator-is-running: .ensure-oc-exists
	@${OC} get pods -l app=kiali-operator -n kiali-operator 2>/dev/null | grep "^kiali-operator.*Running" > /dev/null ;\
	RETVAL=$$?; \
	if [ $$RETVAL -ne 0 ]; then \
	  echo "The Operator is not running. Cannot continue."; exit 1; \
	fi

.ensure-operator-ns-does-not-exist: .ensure-oc-exists
	@_cmd="${OC} get namespace ${OPERATOR_NAMESPACE}"; \
	$$_cmd > /dev/null 2>&1 ; \
	while [ $$? -eq 0 ]; do \
	  echo "Waiting for the operator namespace [${OPERATOR_NAMESPACE}] to terminate" ; \
	  sleep 4 ; \
	  $$_cmd 2> /dev/null; \
	done ; \
	exit 0

## operator-create: Deploy the Kiali operator to the cluster using the install script.
# By default, this target will not deploy Kiali - it will only deploy the operator.
# You can tell it to also install Kiali by setting OPERATOR_INSTALL_KIALI=true.
# The Kiali operator does not create secrets, but this calls the install script
# which can create a Kiali secret for you as a convienence so you don't have
# to remember to do it yourself. It will only do this if it was told to install Kiali.
operator-create: .prepare-cluster operator-delete .ensure-operator-ns-does-not-exist
	@echo Deploy Operator
	${ROOTDIR}/operator/deploy/deploy-kiali-operator.sh \
    --operator-image-name        "${CLUSTER_OPERATOR_INTERNAL_NAME}" \
    --operator-image-pull-policy "${OPERATOR_IMAGE_PULL_POLICY}" \
    --operator-image-version     "${OPERATOR_CONTAINER_VERSION}" \
    --operator-namespace         "${OPERATOR_NAMESPACE}" \
    --operator-watch-namespace   "${OPERATOR_WATCH_NAMESPACE}" \
    --operator-install-kiali     "${OPERATOR_INSTALL_KIALI}" \
    --accessible-namespaces      "${ACCESSIBLE_NAMESPACES}" \
    --auth-strategy              "${AUTH_STRATEGY}" \
    --credentials-username       "${CREDENTIALS_USERNAME}" \
    --credentials-passphrase     "${CREDENTIALS_PASSPHRASE}" \
    --kiali-image-name           "${CLUSTER_KIALI_INTERNAL_NAME}" \
    --kiali-image-pull-policy    "${KIALI_IMAGE_PULL_POLICY}" \
    --kiali-image-version        "${CONTAINER_VERSION}" \
    --namespace                  "${NAMESPACE}"

## operator-delete: Remove the Kiali operator resources from the cluster along with Kiali itself
operator-delete: .ensure-oc-exists kiali-purge
	@echo Remove Operator
	${OC} delete --ignore-not-found=true all,sa,deployments,clusterroles,clusterrolebindings,customresourcedefinitions --selector="app=kiali-operator" -n "${OPERATOR_NAMESPACE}"
	${OC} delete --ignore-not-found=true namespace "${OPERATOR_NAMESPACE}"

## secret-create: Create a Kiali secret using CREDENTIALS_USERNAME and CREDENTIALS_PASSPHRASE.
secret-create: .ensure-oc-exists
	@echo Create the secret
	${OC} create secret generic kiali -n "${NAMESPACE}" --from-literal "username=${CREDENTIALS_USERNAME}" --from-literal "passphrase=${CREDENTIALS_PASSPHRASE}"
	${OC} label secret kiali app=kiali -n "${NAMESPACE}"

## secret-delete: Delete the Kiali secret.
secret-delete: .ensure-oc-exists
	@echo Delete the secret
	${OC} delete --ignore-not-found=true secret --selector="app=kiali" -n "${NAMESPACE}"

## kiali-create: Create a Kiali CR to the cluster, informing the Kiali operator to install Kiali.
ifeq ($(AUTH_STRATEGY),login)
kiali-create: .prepare-cluster secret-create
else
kiali-create: .prepare-cluster
endif
	@echo Deploy Kiali using the settings found in ${KIALI_CR_FILE}
	cat ${KIALI_CR_FILE} | \
ACCESSIBLE_NAMESPACES="${ACCESSIBLE_NAMESPACES}" \
AUTH_STRATEGY="${AUTH_STRATEGY}" \
KIALI_EXTERNAL_SERVICES_PASSWORD="$(shell ${OC} get secrets htpasswd -n ${NAMESPACE} -o jsonpath='{.data.rawPassword}' 2>/dev/null || echo '' | base64 --decode)" \
KIALI_IMAGE_NAME="${CLUSTER_KIALI_INTERNAL_NAME}" \
KIALI_IMAGE_PULL_POLICY="${KIALI_IMAGE_PULL_POLICY}" \
KIALI_IMAGE_VERSION="${CONTAINER_VERSION}" \
NAMESPACE="${NAMESPACE}" \
ROUTER_HOSTNAME="$(shell ${OC} get $(shell ${OC} get routes -n ${NAMESPACE} -o name 2>/dev/null || echo 'noroute' | head -n 1) -n ${NAMESPACE} -o jsonpath='{.status.ingress[0].routerCanonicalHostname}' 2>/dev/null)" \
SERVICE_TYPE="${SERVICE_TYPE}" \
VERBOSE_MODE="${VERBOSE_MODE}" \
envsubst | ${OC} apply -n "${OPERATOR_WATCH_NAMESPACE}" -f -

## kiali-delete: Remove a Kiali CR from the cluster, informing the Kiali operator to uninstall Kiali.
kiali-delete: .ensure-oc-exists secret-delete
	@echo Remove Kiali
	${OC} delete --ignore-not-found=true kiali kiali -n "${OPERATOR_WATCH_NAMESPACE}"

## kiali-purge: Purges all Kiali resources directly without going through the operator or ansible.
kiali-purge: .ensure-oc-exists
	@echo Purge Kiali resources
	${OC} patch kiali kiali -n "${OPERATOR_WATCH_NAMESPACE}" -p '{"metadata":{"finalizers": []}}' --type=merge ; true
	${OC} delete --ignore-not-found=true all,secrets,sa,templates,configmaps,deployments,roles,rolebindings,clusterroles,clusterrolebindings,ingresses,customresourcedefinitions --selector="app=kiali" -n "${NAMESPACE}"
	${OC} delete --ignore-not-found=true oauthclients.oauth.openshift.io --selector="app=kiali" -n "${NAMESPACE}" ; true

## kiali-reload-image: Refreshing the Kiali pod by deleting it which forces a redeployment
kiali-reload-image: .ensure-oc-exists
	@echo Refreshing Kiali pod within namespace ${NAMESPACE}
	${OC} delete pod --selector=app=kiali -n ${NAMESPACE}

## run-operator-playbook: Run the operator dev playbook to run the operator ansible script locally.
run-operator-playbook:
	ansible-playbook -vvv -i ${ROOTDIR}/operator/dev-hosts ${ROOTDIR}/operator/dev-playbook.yml

## run-operator-playbook-tag: Run a tagged set of tasks via operator dev playbook to run parts of the operator ansible script locally.
# To use this, add "tags: test" to one or more tasks - those are the tasks that will be run.
run-operator-playbook-tag:
	ansible-playbook -vvv -i ${ROOTDIR}/operator/dev-hosts ${ROOTDIR}/operator/dev-playbook.yml --tags test

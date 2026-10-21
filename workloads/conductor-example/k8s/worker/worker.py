"""The worker for gcp_web_identity: the step of a Conductor workflow that reaches Google Cloud.

It asks the Workload API for a JWT-SVID with the SPIFFE library, exchanges it at Google's Security
Token Service through Workload Identity Federation, and impersonates a Google service account with
the result. The only credential is the identity the Defakto agent attested for this pod. No
service account key is stored anywhere, and the tokens never leave the process except to Google.
"""
import json
import os
import signal
import sys
import time
import urllib.error
import urllib.request

from conductor.client.automator.task_handler import TaskHandler
from conductor.client.configuration.configuration import Configuration
from conductor.client.worker.exception import NonRetryableException
from conductor.client.worker.worker_task import worker_task
from conductor.client.workflow.conductor_workflow import ConductorWorkflow
from conductor.client.workflow.executor.workflow_executor import WorkflowExecutor
from spiffe import WorkloadApiClient

# Must match --allowed-audiences on the Workload Identity Pool provider.
AUDIENCE = 'gcp-demo'
SCOPE = 'https://www.googleapis.com/auth/cloud-platform'


def post_json(url: str, body: dict, token: str = '') -> dict:
    req = urllib.request.Request(url, data=json.dumps(body).encode(), method='POST',
                                 headers={'Content-Type': 'application/json'})
    if token:
        req.add_header('Authorization', f'Bearer {token}')
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        # Google's error body names the reason; the status line alone does not.
        raise RuntimeError(f'{url}: {e.code} {e.read().decode(errors="replace")}') from e


@worker_task(task_definition_name='gcp_web_identity', register_task_def=True)
def gcp_web_identity() -> dict:
    try:
        # SPIFFE_ENDPOINT_SOCKET, which the Defakto controller webhook sets, names the Workload API.
        # A fresh token per run: JWT-SVIDs are short-lived, so none is cached.
        with WorkloadApiClient(default_timeout=10) as client:
            svid = client.fetch_jwt_svid(audience={AUDIENCE})
        # Google's STS checks the issuer, signature, and audience against the pool's provider.
        federated = post_json('https://sts.googleapis.com/v1/token', {
            'grantType': 'urn:ietf:params:oauth:grant-type:token-exchange',
            'audience': f'//iam.googleapis.com/{os.environ["GCP_PROVIDER"]}',
            'scope': SCOPE,
            'requestedTokenType': 'urn:ietf:params:oauth:token-type:access_token',
            'subjectToken': svid.token,
            'subjectTokenType': 'urn:ietf:params:oauth:token-type:jwt',
        })['access_token']
        # The service account's IAM binding decides whether this SPIFFE ID may act as it.
        account = os.environ['GCP_SERVICE_ACCOUNT']
        impersonated = post_json(
            f'https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/{account}:generateAccessToken',
            {'scope': [SCOPE], 'lifetime': '900s'}, token=federated)
        return {'sub': str(svid.spiffe_id), 'service_account': account,
                'expires': impersonated['expireTime']}
    except Exception as e:
        # The run fails at once with the reason, rather than after the SDK's default retries.
        raise NonRetryableException(str(e)) from e


def register(executor: WorkflowExecutor) -> None:
    workflow = ConductorWorkflow(name='gcp_federation', executor=executor, version=1,
                                 description="One step that reaches Google Cloud with the worker's JWT-SVID and no stored key")
    task = gcp_web_identity(task_ref_name='gcp_web_identity')
    workflow >> task
    workflow.timeout_seconds(120)
    workflow.output_parameters({'sub': task.output('sub'),
                                'service_account': task.output('service_account'),
                                'expires': task.output('expires')})
    workflow.register(overwrite=True)


if __name__ == '__main__':
    # CONDUCTOR_SERVER_URL names the server.
    config = Configuration()
    # The server may still be starting; registering is idempotent, so a restart just does it again.
    while True:
        try:
            register(WorkflowExecutor(configuration=config))
            break
        except Exception as e:
            print(f'waiting for {config.host}: {e}', flush=True)
            time.sleep(5)
    print('registered gcp_federation; polling gcp_web_identity', flush=True)
    handler = TaskHandler(configuration=config)
    handler.start_processes()
    # As PID 1 the process ignores SIGTERM unless it handles it, and a pod in its grace period
    # would go on taking tasks.
    signal.signal(signal.SIGTERM, lambda *_: (handler.stop_processes(), sys.exit(0)))
    handler.join_processes()

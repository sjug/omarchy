#!/bin/bash

# Scoped Kimi Code logins must never borrow another environment's credentials.
# Keep the fork's regressions after upstream's broader collector-test pruning.
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
source "$SHELL_TEST_DIR/agent-usage-helpers.sh"
agent_sandbox

python3 - <<'PYTEST'
from agent_usage_fixtures import *
import threading

state = {}

def token_reply(request):
  check("OAuth traffic identifies the collector to Kimi's edge", request.get_header("User-agent") == "omarchy-agent-usage/1")
  if state.get("token_hook"):
    state["token_hook"]()
  return {"access_token": "AT_new", "refresh_token": "RT_new", "expires_in": 3600}


def auth_header():
  return http.requests[-1]["headers"].get("authorization") if http.requests else None


def credentials(token="AT_old", expiry=None):
  path = scanner.CREDENTIALS_PATH
  path.parent.mkdir(parents=True, exist_ok=True)
  path.write_text(json.dumps({"access_token": token, "refresh_token": "RT_old",
                              "expires_at": time.time() - 10 if expiry is None else expiry}))


def record():
  return run_main(scanner, "--force", "--limits-only")


SCOPED_NAME = "kimi-code-env-0e4f99c69cc27850"


def scoped_config(path):
  path.mkdir(parents=True, exist_ok=True)
  (path / "config.toml").write_text('''[providers."managed:kimi-code"]
type = "kimi"
base_url = "https://api.kimi.ai/coding/v1"
oauth = {storage = "file", key = "oauth/kimi-code-env-0e4f99c69cc27850", oauth_host = "https://auth.kimi.ai"}
''')
  # A stale install-channel marker must not override the persisted login.
  (path / "region").write_text("mainland-cn")


def scoped_store(root):
  global scanner
  del os.environ["KIMI_CODE_HOME"]
  native = home() / ".kimi-code"
  scoped_config(native)
  write_json(home() / ".kimi" / "credentials" / "kimi-code.json", {"access_token": "AT_legacy"})
  write_json(native / "credentials" / "kimi-code.json", {"access_token": "AT_default"})
  scanner = load_collector("kimi")
  expect("the managed configuration selects its scoped store and both endpoints",
         [scanner.CREDENTIALS_PATH, scanner.USAGE_URL, scanner.TOKEN_URL],
         [native / "credentials" / (SCOPED_NAME + ".json"), "https://api.kimi.ai/coding/v1/usages", "https://auth.kimi.ai/api/oauth/token"])
  expect("a missing scoped login cannot borrow the default or legacy account", record()["usageStatusText"], "Waiting for auth")
  credentials()
  state["token_hook"] = lambda: check("refresh holds this credential's native lock", (native / "oauth" / (SCOPED_NAME + ".lock")).is_dir())
  data = record()
  expect("a scoped login refreshes and supplies live limits", [bool(data["limits"]), auth_header()], [True, "Bearer AT_new"])
  expect("rotation leaves the default account alone", json.loads((native / "credentials" / "kimi-code.json").read_text()), {"access_token": "AT_default"})


def scoped_cli_lock(root):
  global scanner
  scoped_config(root / "code home")
  scanner = load_collector("kimi")
  credentials()
  lock = root / "code home" / "oauth" / (SCOPED_NAME + ".lock")
  lock.mkdir(parents=True)

  def peer():
    time.sleep(0.3)
    credentials("AT_peer", time.time() + 3600)
    lock.rmdir()

  thread = threading.Thread(target=peer)
  thread.start()
  try:
    token = scanner.api_key()
  finally:
    thread.join()
  expect("the scoped CLI lease prevents a second refresh", [token, http.count], ["AT_peer", 0])


def scoped_override(root):
  global scanner
  scoped_config(root / "code home")
  scanner = load_collector("kimi")
  credentials("AT_scoped", time.time() + 3600)
  os.environ["KIMI_CODE_BASE_URL"] = "https://api.kimi.com/coding/v1/"
  scanner = load_collector("kimi")
  expect("a base URL override resets the OAuth host and selects the default slot",
         [scanner.CREDENTIALS_PATH.name, scanner.USAGE_URL, scanner.TOKEN_URL, record()["usageStatusText"]],
         ["kimi-code.json", "https://api.kimi.com/coding/v1/usages", "https://auth.kimi.com/api/oauth/token", "Waiting for auth"])
  os.environ["KIMI_OAUTH_HOST"] = "https://auth.kimi.ai/"
  scanner = load_collector("kimi")
  check("an OAuth host override selects another isolated slot", scanner.CREDENTIALS_PATH.stem not in ("kimi-code", SCOPED_NAME))
  expect("the legacy OAuth env override is honored", scanner.TOKEN_URL, "https://auth.kimi.ai/api/oauth/token")
  os.environ["KIMI_CODE_OAUTH_HOST"] = "https://auth.kimi.com"
  os.environ["KIMI_API_KEY"] = "AT_env"
  scanner = load_collector("kimi")
  expect("the Code host override wins and an explicit API key still works", [scanner.CREDENTIALS_PATH.name, scanner.api_key()], ["kimi-code.json", "AT_env"])


def invalid_config(root):
  global scanner
  path = root / "code home"
  scoped_config(path)
  credentials("AT_default", time.time() + 3600)
  (path / "config.toml").write_text("[broken")
  scanner = load_collector("kimi")
  data = record()
  expect("a broken config cannot select a different account", [data["usageStatusText"], http.count], ["Kimi limits unavailable", 0])
  check("a broken config has a useful diagnostic", "config.toml" in data["authHelpText"])
  os.environ["KIMI_API_KEY"] = "AT_env"
  expect("an explicit API key is usable despite a broken config", scanner.api_key(), "AT_env")
  del os.environ["KIMI_API_KEY"]
  (path / "config.toml").write_text('[providers."managed:kimi-code"]\nbase_url = 42\n')
  scanner = load_collector("kimi")
  expect("an invalid endpoint type cannot expose a stored token", [record()["usageStatusText"], http.count], ["Kimi limits unavailable", 0])
  scoped_config(path)
  os.environ["KIMI_CODE_OAUTH_HOST"] = ""
  scanner = load_collector("kimi")
  expect("an empty host override cannot select the default account", [record()["usageStatusText"], http.count], ["Kimi limits unavailable", 0])


def mismatched_ref(root):
  global scanner
  path = root / "code home"
  scoped_config(path)
  config = path / "config.toml"
  config.write_text(config.read_text().replace("oauth/" + SCOPED_NAME, "oauth/../../outside"))
  scanner = load_collector("kimi")
  expect("a mismatched or unsafe ref is re-derived as in native Kimi", scanner.CREDENTIALS_PATH, path / "credentials" / (SCOPED_NAME + ".json"))
  config.write_text(config.read_text().replace("oauth/../../outside", "oauth/" + SCOPED_NAME).replace('storage = "file"', 'storage = "keyring"'))
  scanner = load_collector("kimi")
  credentials("AT_decoy", time.time() + 3600)
  data = record()
  expect("keyring auth cannot borrow a file credential", [data["usageStatusText"], http.count], ["Kimi limits unavailable", 0])
  check("unsupported storage has a useful diagnostic", "keyring" in data["authHelpText"])



for case in (scoped_store, scoped_cli_lock, scoped_override, invalid_config, mismatched_ref):
  state.clear()
  root = Path(tempfile.mkdtemp(prefix="kimi scoped.", dir=os.environ["SANDBOX"]))
  sandbox(root)
  os.environ["KIMI_CODE_HOME"] = str(root / "code home")
  scanner = load_collector("kimi")
  with FakeHttp({"/api/oauth/token": token_reply, "/coding/v1/usages": {"usages": {"limit_5h": {"used_ratio": 0.25}}}}) as http:
    case(root)
PYTEST

# Local-first AI providers — incremental implementation

Status: opt-in providers and an in-game plain-text/PNG review panel implemented and neutral-mock-tested.
**No automatic gameplay dialogue replacement or asset import; not present in the frozen v3 APK,
and not tested on a phone or against real AI servers.**
No server was installed, started, reconfigured or exposed by this pass; only a temporary loopback mock ran.
No emulator, adb, APK install, export, publication or writes to `build/android-game-preview` occurred.

## Implemented surface

`game/src/integrations/ai/provider_client.gd` is a Node that callers explicitly instantiate and add to a
scene. It is not an autoload and has no automatic connection, generation, gameplay mutation or asset import.

| Provider | Supported API | Result / limits |
|---|---|---|
| LM Studio / OpenAI-compatible chat | `GET /v1/models`, `POST /v1/chat/completions` | Text-only, non-streaming, selected model, up to 256 output tokens; authored caller-supplied fallback on failure |
| ComfyUI | `GET /system_stats`, `POST /prompt`, `GET /history/{id}`, `GET /view` | User-supplied API graph; manual status checks and bounded PNG preview. Queue acceptance is not completion |
| AUTOMATIC1111 (optional) | `GET /sdapi/v1/options`, `POST /sdapi/v1/txt2img` | Single 512×512 image request, 12 steps; bounded base64 PNG validation/preview, never saved/applied |

Asset import, generation cancellation, streaming, tools, vision, conversation persistence and scheduling
are **not implemented**. A completed response means
review is required, not that an asset is suitable, rights-cleared or integrated. Backend plugins/API changes
and authentication differences may require more adapters. Only Bearer-token headers are supported here;
AUTOMATIC1111 Basic authentication is not implemented.

## Configuration

`provider_config.gd` supplies disabled-by-default settings. The game's **Local AI** button opens a separate
review window (omitted in vanilla mode). Opening pauses gameplay, preserves an existing pause, and makes
no connection. Enable requests, enter a server root/model, approve each exact LAN root, then explicitly test
or request an output. Only manually entered text/workflows are sent; game state is not captured.

Apply/save persists validated non-secret settings to `local_ai/providers.json` under the game's save
directory. Session tokens and LAN grants are never persisted; closing clears them. Environment-variable
names (not their values) can be saved for desktop use. Endpoint edits clear credential fields and consent.
Changed input/settings or a closed panel cause pending results to be discarded, not applied later.
The client is not an autoload; callers can also validate a Dictionary then call `configure()` directly.

```json
{
  "enabled": true,
  "timeout_seconds": 10,
  "max_response_bytes": 8388608,
  "dialogue": {
    "provider": "lm_studio",
    "base_url": "http://127.0.0.1:1234",
    "model": "USER_SELECTED_MODEL_ID",
    "api_key_env": "SDT_LM_STUDIO_API_KEY"
  },
  "images": {
    "provider": "comfyui",
    "base_url": "http://127.0.0.1:8188"
  }
}
```

Use server roots, **not** `/v1` or another URL path. Set `images.provider` to `automatic1111` and select its
server root to use that optional protocol. Models/checkpoints and ComfyUI workflows must already be available
on the user's worker. No models, workflows, custom nodes, weights or third-party assets are bundled.

Never put a key in source, JSON config, URL, screenshot or log. `api_key_env` names an environment variable;
it does not contain a credential. Alternatively call `set_session_token("dialogue", token)` or
`set_session_token("images", token)` using a credential supplied securely at runtime. Tokens remain in memory,
are cleared by `configure()`/`clear_session_tokens()`, and are not returned in error messages. The module does
not implement an OS credential vault; Android process environment variables are not a suitable credential UI.

Configuration validation rejects unknown fields (including inline API keys), unsupported providers,
non-finite/invalid timeouts and unsafe endpoints. Timeout is 1–30 seconds; response/serialized-request limit
is 1 KiB–16 MiB. The HTTP transport allows one request at a time and returns `busy` rather than growing a
queue. There are no automatic retries. A timeout does **not** cancel an already queued remote GPU job.

## Consent and network policy

- Allowed roots: `localhost`, loopback IPs, RFC1918 IPv4, and IPv6 ULA. Public, wildcard, metadata/link-local,
  hostname/DNS, credential-bearing, query/fragment and path-bearing roots are rejected. IPv6 uses brackets.
- Loopback needs explicit feature enablement but no LAN grant. **Every LAN root needs a session-only grant**
  through `allow_lan_endpoint(exact_root)` after an explicit user approval explaining what will be sent.
  Loading config alone cannot grant LAN consent. Reconfiguring revokes all grants and session tokens.
- The review UI lets users review the endpoint and approve sending entered text or an image workflow.
  Do not call the grant method automatically from config loading, a mod, a model response or a reconnect timer.
- Redirects are disabled. DNS aliases other than localhost are deliberately unsupported to avoid DNS-based
  escape from the local-only policy. TLS certificate verification is not disabled for self-signed servers.
- Plain HTTP can expose prompts, responses and Bearer tokens to the local network. Prefer HTTPS with a
  trusted certificate; only permit cleartext on a deliberately approved trusted LAN. Local-only is not the
  same as authenticated or encrypted. This adapter is not a sandbox for executable plugins.
- Keep inference servers loopback-only by default. If phone access is explicitly approved, bind a specific
  private interface and firewall access to approved devices; require authentication/TLS as appropriate.
  **No wildcard/public binding, router forwarding, UPnP opening, public tunnel or firewall changes are made
  or authorized by this integration.** Tethering can change addresses/routing; recheck rather than exposing
  a server broadly to make discovery easier.

PNG preview accepts at most 8 MiB, 4096 pixels per axis and 4,194,304 pixels total. Header dimensions are
checked before decoding. ComfyUI references allow only PNG filenames and safe relative subfolders in
`output`/`temp`; no arbitrary URL or filesystem import is accepted. Text is displayed in a plain TextEdit,
never sent to the game's action-tag parser. Previewing is not rights clearance or approval to redistribute.

## Caller example (separate from the review UI)

```gdscript
const ProviderClient = preload("res://src/integrations/ai/provider_client.gd")

func optional_reply(config: Dictionary) -> String:
    var client := ProviderClient.new()
    add_child(client)
    if not client.configure(config).ok:
        client.queue_free()
        return "Welcome back."
    # For LAN, a separate user-confirmation flow must approve the exact root first.
    var answer: Dictionary = await client.dialogue(
        [{"role": "user", "content": "Say a short, friendly hello."}], "Welcome back.")
    client.queue_free()
    return answer.text
```

Do not replace an authored line until the game has an explicit integration/review policy. Errors such as
disabled, missing model, unavailable server, HTTP failure, invalid JSON/schema, oversized response, timeout
or missing LAN consent return failure plus the unchanged caller-supplied fallback. No fabricated completion
is substituted. Call `connectivity("dialogue")` / `connectivity("images")` only when a user requests a check;
successful connectivity alone does not prove model readiness, generation quality or API parity.

## Android and other client limitations

- The current v3 APK is immutable and does not include this code or a network-permission update. No claim
  is made that its networking, phone install or provider access works.
- `127.0.0.1` on a phone is the **phone**, not the development PC. A future phone build needs a reachable,
  explicitly approved private endpoint and Android `INTERNET` permission. Configure any necessary Android
  cleartext exception narrowly in that future build; do not globally weaken network security or TLS checks.
- Review UI source includes LAN approval, session-only token fields, profiles and connection status;
  phone layout, keyboard/focus, resize and accessibility remain unverified.
  Wi-Fi client isolation, tethering, VPNs, captive portals, certificates,
  offline/background behavior and suspended requests require actual device tests.
- Inference remains on the configured worker; nothing installs/runs a desktop model on the phone.
  Web/CORS, mixed-content and private-network browser restrictions are also unverified.

## Tests and next gates

```sh
python3 -W error::ResourceWarning -m unittest discover -s tests -p test_ai_providers.py -v
```

The Godot fixture stages only these integration scripts and atomic storage, not the game or its assets. Tests use a mock
transport and a Python HTTP server bound exclusively to `127.0.0.1` on an ephemeral port, then shut it down.
They cover disabled fallback, endpoint restrictions, LAN consent/revocation, config limits, header-injection
rejection, protocol contracts and invalid JSON/schema, HTTP failures, redirects, oversize responses and timeout.
ComfyUI queue/history/download and optional AUTOMATIC1111 payloads are mocked; no real image/model executes.
Tests also cover PNG validation, profile round trips, exact-endpoint UI approval, plain-text action tags,
pause restoration and discarding delayed responses. The manual desktop CI matrix is configured for Linux,
Windows and macOS, but only local Linux execution has been verified here.

Next gates: rendered game/UI acceptance, real-server versioned smoke tests with explicit authorization,
reviewed workflow provenance, explicit approved-import design,
and separately authorized phone/network-security testing. Generated content must remain review-only with
source/workflow/model/license provenance; public availability never establishes reuse rights.

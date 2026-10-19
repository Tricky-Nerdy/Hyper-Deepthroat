extends Node
## Single bounded request. No redirects, retries, insecure TLS override or raw-error-body logging.

var _busy := false


func send(method: int, url: String, headers: PackedStringArray, payload: Dictionary,
		timeout_seconds: float, max_bytes: int) -> Dictionary:
	var response := await send_binary(method, url, headers, payload, timeout_seconds, max_bytes)
	if not response.ok:
		return response
	var parser := JSON.new()
	if parser.parse((response.bytes as PackedByteArray).get_string_from_utf8()) != OK or not parser.data is Dictionary:
		return {"ok": false, "error": "invalid_json"}
	return {"ok": true, "data": parser.data}


func send_binary(method: int, url: String, headers: PackedStringArray, payload: Dictionary,
		timeout_seconds: float, max_bytes: int) -> Dictionary:
	if _busy:
		return {"ok": false, "error": "busy"}
	if not is_inside_tree():
		return {"ok": false, "error": "transport_not_in_tree"}
	_busy = true
	var request := HTTPRequest.new()
	request.timeout = timeout_seconds
	request.body_size_limit = max_bytes
	request.max_redirects = 0
	add_child(request)
	var body := "" if method == HTTPClient.METHOD_GET else JSON.stringify(payload)
	if body.to_utf8_buffer().size() > max_bytes:
		request.queue_free()
		_busy = false
		return {"ok": false, "error": "request_too_large"}
	var started := request.request(url, headers, method, body)
	if started != OK:
		request.queue_free()
		_busy = false
		return {"ok": false, "error": "unavailable"}
	var response: Array = await request.request_completed
	request.queue_free()
	_busy = false
	if response[0] != HTTPRequest.RESULT_SUCCESS:
		return {"ok": false, "error": "transport_failed"}
	var status: int = response[1]
	if status < 200 or status >= 300:
		return {"ok": false, "error": "http_error", "status": status}
	return {"ok": true, "bytes": response[3]}

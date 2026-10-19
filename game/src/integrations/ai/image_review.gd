extends RefCounted
## Untrusted provider images are review-only PNGs, never game assets or executable resources.
const MAX_BYTES := 8388608
const MAX_AXIS := 4096
const MAX_PIXELS := 4194304


static func png(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() < 33 or bytes.size() > MAX_BYTES:
		return {"ok": false, "error": "image_size_invalid"}
	if bytes.slice(0, 8) != PackedByteArray([137, 80, 78, 71, 13, 10, 26, 10]) \
		or bytes.slice(8, 16) != PackedByteArray([0, 0, 0, 13, 73, 72, 68, 82]):
		return {"ok": false, "error": "png_required"}
	var width := _u32(bytes, 16)
	var height := _u32(bytes, 20)
	if width < 1 or height < 1 or width > MAX_AXIS or height > MAX_AXIS or width * height > MAX_PIXELS:
		return {"ok": false, "error": "image_dimensions_exceeded"}
	var image := Image.new()
	if image.load_png_from_buffer(bytes) != OK:
		return {"ok": false, "error": "invalid_png"}
	if image.get_width() != width or image.get_height() != height:
		return {"ok": false, "error": "image_dimensions_mismatch"}
	return {"ok": true, "state": "review_required", "image": image}


static func base64_png(encoded: String) -> Dictionary:
	if encoded.length() > (MAX_BYTES * 4 / 3 + 8) or encoded.begins_with("data:"):
		return {"ok": false, "error": "raw_base64_png_required"}
	var alphabet := RegEx.new()
	alphabet.compile("^[A-Za-z0-9+/]*={0,2}$")
	if encoded.is_empty() or encoded.length() % 4 != 0 or alphabet.search(encoded) == null:
		return {"ok": false, "error": "raw_base64_png_required"}
	return png(Marshalls.base64_to_raw(encoded))


static func _u32(bytes: PackedByteArray, at: int) -> int:
	return (int(bytes[at]) << 24) | (int(bytes[at + 1]) << 16) | (int(bytes[at + 2]) << 8) | int(bytes[at + 3])


static func comfy_route(record: Dictionary) -> Dictionary:
	var filename = record.get("filename")
	var folder = record.get("subfolder", "")
	var kind = record.get("type", "output")
	if not filename is String or not folder is String or kind not in ["output", "temp"]:
		return {"ok": false, "error": "invalid_image_reference"}
	if not filename.to_lower().ends_with(".png") or not _component(filename) or filename.length() > 128 \
		or folder.length() > 256 or folder.begins_with("/"):
		return {"ok": false, "error": "invalid_image_reference"}
	if folder != "":
		for part in folder.split("/"):
			if not _component(part):
				return {"ok": false, "error": "invalid_image_reference"}
	return {"ok": true, "route": "/view?filename=" + filename.uri_encode() + "&subfolder=" + folder.uri_encode() + "&type=" + kind}


static func _component(value: String) -> bool:
	if value == "" or value.contains(".."):
		return false
	for character in value:
		if not (character in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.- "):
			return false
	return true

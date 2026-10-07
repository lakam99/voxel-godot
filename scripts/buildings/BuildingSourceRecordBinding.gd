extends RefCounted
## Canonical source record encoding shared by admitted plans and publishers.
static func encode(record: Dictionary) -> String:
	var encoded := var_to_bytes(record)
	encoded.fill(0)
	if encoded.encode_var(0, record) != encoded.size(): return ""
	return encoded.hex_encode()

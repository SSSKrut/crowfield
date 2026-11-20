class_name KnownServers
extends RefCounted
## KnownServers remembers the certificate of every server the client joined,
## like the known hosts of SSH: the first connection trusts the server, later
## ones make sure it is still the same. The file lists an address and a
## fingerprint per line; the certificates themselves lie next to it, in
## servers/<fingerprint>.crt, since a client pins the certificate itself.

var path: String
var servers := {}


## load_file reads the file; a missing one is empty. It returns the servers, or
## the error as a String.
static func load_file(file_path: String) -> Variant:
	var known := KnownServers.new()
	known.path = file_path
	if not FileAccess.file_exists(file_path):
		return known
	var text := FileAccess.get_file_as_string(file_path)
	var line_number := 0
	for line in text.split("\n"):
		line_number += 1
		var trimmed := line.strip_edges()
		if trimmed == "" or trimmed.begins_with("#"):
			continue
		var fields := trimmed.split(" ", false)
		if fields.size() != 2:
			return "%s:%d: want an address and a fingerprint" % [file_path, line_number]
		if not Certificates.is_fingerprint(fields[1]):
			return "%s:%d: the fingerprint must be 64 hex digits" % [file_path, line_number]
		known.servers[fields[0]] = fields[1].to_lower()
	return known


func lookup(address: String) -> String:
	return servers.get(address, "")


## certificate is the remembered certificate with a fingerprint, or null.
func certificate(fingerprint: String) -> X509Certificate:
	var file := _certificate_path(fingerprint)
	if not FileAccess.file_exists(file):
		return null
	var certificate := X509Certificate.new()
	if certificate.load(file) != OK or Certificates.fingerprint(certificate) != fingerprint:
		return null
	return certificate


## remember stores the certificate of a server and rewrites the file. It
## returns an error, or "".
func remember(address: String, certificate: X509Certificate) -> String:
	var fingerprint := Certificates.fingerprint(certificate)
	DirAccess.make_dir_recursive_absolute(_certificate_path(fingerprint).get_base_dir())
	if certificate.save(_certificate_path(fingerprint)) != OK:
		return "cannot write %s" % _certificate_path(fingerprint)
	servers[address] = fingerprint
	var addresses: Array = servers.keys()
	addresses.sort()
	var text := "# Servers this client joined: address and certificate fingerprint.\n"
	for each in addresses:
		text += "%s %s\n" % [each, servers[each]]
	var temporary := path + ".new"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return "cannot write %s" % temporary
	file.store_string(text)
	file.close()
	if DirAccess.rename_absolute(temporary, path) != OK:
		return "cannot replace %s" % path
	return ""


func _certificate_path(fingerprint: String) -> String:
	return path.get_base_dir().path_join("servers").path_join(fingerprint + ".crt")


## check decides whether to trust the server at address, which showed the
## certificate seen. A fingerprint given by the player must match; otherwise a
## remembered one must, and the first one is remembered. It returns
## [message to log, error]; known may be null to remember nothing.
static func check(known: KnownServers, address: String, given: String, seen: X509Certificate) -> Array:
	var fingerprint := Certificates.fingerprint(seen)
	if given != "":
		if fingerprint != given.to_lower():
			return ["", "the server at %s has certificate fingerprint %s, not the %s given" % [address, fingerprint, given]]
		if known != null and known.lookup(address) != fingerprint:
			return ["remembered the fingerprint of %s in %s" % [address, known.path], known.remember(address, seen)]
		return ["", ""]
	if known == null:
		return ["connected to %s, certificate fingerprint %s (pass -fingerprint to pin it)" % [address, fingerprint], ""]
	var remembered := known.lookup(address)
	if remembered == "":
		return ["first connection to %s: remembered its certificate fingerprint %s in %s" % [address, fingerprint, known.path],
			known.remember(address, seen)]
	if remembered != fingerprint:
		return ["", ("the server at %s shows another certificate than before: fingerprint %s, remembered %s. " +
			"Someone may be in between. If the server got a new certificate, connect once with -fingerprint %s; " +
			"remembered servers are in %s") % [address, fingerprint, remembered, fingerprint, known.path]]
	if known.certificate(fingerprint) == null:
		return ["", known.remember(address, seen)]
	return ["", ""]

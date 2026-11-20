class_name Certificates
## Certificates of servers. Servers use self-signed certificates, so clients
## pin the certificate itself, identified by its fingerprint: the SHA-256 of
## its DER form in hex, as SSH pins host keys (ARCHITECTURE.md, 6.11).

const COMMON_NAME := "crowfield server"


## generate creates a self-signed server certificate: [certificate, key].
static func generate() -> Array:
	var crypto := Crypto.new()
	var key := crypto.generate_rsa(2048)
	var now := Time.get_datetime_dict_from_system(true)
	var not_before := "%04d%02d%02d000000" % [now.year - 1, now.month, mini(now.day, 28)]
	var not_after := "%04d%02d%02d000000" % [now.year + 10, now.month, mini(now.day, 28)]
	var certificate := crypto.generate_self_signed_certificate(key, "CN=%s,O=Crowfield" % COMMON_NAME, not_before, not_after)
	return [certificate, key]


## load_or_create reads the server certificate from two PEM files, or creates
## and stores one on the first run, so its fingerprint stays the same. It
## returns [certificate, key], or the error as a String.
static func load_or_create(certificate_path: String, key_path: String) -> Variant:
	if FileAccess.file_exists(certificate_path) or FileAccess.file_exists(key_path):
		var certificate := X509Certificate.new()
		var key := CryptoKey.new()
		if certificate.load(certificate_path) != OK:
			return "cannot read the certificate %s" % certificate_path
		if key.load(key_path) != OK:
			return "cannot read the key %s" % key_path
		return [certificate, key]
	var made := generate()
	var dir := key_path.get_base_dir()
	if dir != "" and not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	if made[1].save(key_path) != OK:
		return "cannot write the key %s" % key_path
	FileAccess.set_unix_permissions(key_path, FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER)
	if made[0].save(certificate_path) != OK:
		return "cannot write the certificate %s" % certificate_path
	return made


## pem returns the PEM form of a certificate. It goes through a file: the
## engine's save_to_string counts the closing NUL character into the text.
static func pem(certificate: X509Certificate) -> String:
	var scratch := OS.get_user_data_dir().path_join("certificate-%d-%d.pem" % [OS.get_process_id(), Time.get_ticks_usec()])
	if certificate.save(scratch) != OK:
		return ""
	var text := FileAccess.get_file_as_string(scratch)
	DirAccess.remove_absolute(scratch)
	return text


## der returns the DER form of a certificate.
static func der(certificate: X509Certificate) -> PackedByteArray:
	var pem := pem(certificate)
	var start := pem.find("-----BEGIN CERTIFICATE-----")
	var end := pem.find("-----END CERTIFICATE-----")
	if start < 0 or end < 0:
		return PackedByteArray()
	var body := pem.substr(start + 27, end - start - 27).strip_escapes().replace(" ", "")
	return Marshalls.base64_to_raw(body)


static func fingerprint(certificate: X509Certificate) -> String:
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_SHA256)
	hashing.update(der(certificate))
	return hashing.finish().hex_encode()


static func is_fingerprint(text: String) -> bool:
	if text.length() != 64:
		return false
	for c in text:
		if not c in "0123456789abcdefABCDEF":
			return false
	return true


## from_pem reads a certificate, or returns null.
static func from_pem(pem: String) -> X509Certificate:
	var certificate := X509Certificate.new()
	if pem == "" or certificate.load_from_string(pem) != OK:
		return null
	return certificate


## common_name finds the common name the certificate gives its subject, which
## a client must expect when it pins the certificate.
static func common_name(certificate: X509Certificate) -> String:
	var bytes := der(certificate)
	var found := ""
	# The attribute type 2.5.4.3 (55 04 03) is followed by a string; in a
	# self-signed certificate the issuer and the subject name the same.
	for i in range(bytes.size() - 5):
		if bytes[i] == 0x06 and bytes[i + 1] == 0x03 and bytes[i + 2] == 0x55 and bytes[i + 3] == 0x04 and bytes[i + 4] == 0x03:
			var tag := bytes[i + 5]
			var length := bytes[i + 6] if i + 6 < bytes.size() else 0
			if tag in [0x0C, 0x13, 0x16] and length < 0x80 and i + 7 + length <= bytes.size():
				found = bytes.slice(i + 7, i + 7 + length).get_string_from_utf8()
	return found


## server_options lets a server speak DTLS with its certificate.
static func server_options(certificate: X509Certificate, key: CryptoKey) -> TLSOptions:
	return TLSOptions.server(key, certificate)


## pinned_options lets a client accept only the given certificate.
static func pinned_options(certificate: X509Certificate) -> TLSOptions:
	return TLSOptions.client(certificate, common_name(certificate))


## probe_options lets a client reach a server whose certificate it does not
## know yet, to ask for it; nothing else goes over such a connection.
static func probe_options() -> TLSOptions:
	return TLSOptions.client_unsafe()

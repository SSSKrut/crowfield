class_name Connector
extends RefCounted
## Connector opens a connection to a remote server and makes sure it is the
## server the player means (ARCHITECTURE.md, 6.11). The connection itself only
## accepts the pinned certificate. A certificate the client does not know yet
## it learns first over a probe: a connection that asks the server for its
## certificate and nothing else. Poll it every frame until done() or failed().

const TIMEOUT := 5.0

enum Stage { PROBE, VERIFIED, DONE, FAILED }

var conn: Conn
var error := ""
## message is what to tell the player about the certificate, if anything.
var message := ""
var _address: String
var _given: String
var _known: KnownServers
var _stage := Stage.PROBE
var _pending: ENetTransport.Client
var _started := 0.0
var _asked := false
## _pinned is the certificate the verified connection accepts.
var _pinned: X509Certificate
## _diagnosing tells a probe after a failed verified connection, to say why.
var _diagnosing := false


## _init starts a connection to address; given is the fingerprint the player
## asks for, or empty; config_dir keeps the known servers, or is empty to
## remember nothing.
func _init(address: String, given: String, config_dir: String) -> void:
	_address = address
	_given = given.to_lower()
	if given != "" and not Certificates.is_fingerprint(given):
		_fail("a fingerprint is 64 hex digits")
		return
	if config_dir != "":
		var loaded: Variant = KnownServers.load_file(config_dir.path_join("known_servers"))
		if loaded is String:
			_fail(loaded)
			return
		_known = loaded
	var fingerprint := _given
	if fingerprint == "" and _known != null:
		fingerprint = _known.lookup(address)
	if fingerprint != "" and _known != null:
		_pinned = _known.certificate(fingerprint)
	if _pinned != null:
		_dial_verified()
	else:
		_dial_probe()


func done() -> bool:
	return _stage == Stage.DONE


func failed() -> bool:
	return _stage == Stage.FAILED


func poll() -> void:
	if _pending == null:
		return
	_pending.poll()
	var late := ClientSession._now() - _started > TIMEOUT
	match _stage:
		Stage.PROBE:
			_poll_probe(late)
		Stage.VERIFIED:
			if _pending.is_ready():
				conn = _pending
				_pending = null
				_stage = Stage.DONE
			elif late or not _pending.is_open():
				# The server did not take the pinned certificate, or does not
				# answer: a probe tells which.
				_pending.close("handshake failed")
				_diagnosing = true
				_dial_probe()


func _poll_probe(late: bool) -> void:
	# The server closes a probe right after its answer: the answer is read
	# before the connection is taken for lost.
	var answer := _pending.receive_reliable() if _asked else []
	if answer.is_empty():
		if late or not _pending.is_open():
			_pending.close("no certificate")
			_fail("cannot reach the server at %s" % _address)
			return
		if _pending.is_ready() and not _asked:
			_pending.send_reliable(Conn.Channel.CONTROL, Protocol.encode(Messages.CertificateRequest.new()))
			_asked = true
		return
	_pending.close("certificate received")
	var certificate := Messages.Certificate.new()
	var seen: X509Certificate = null
	if Protocol.decode_into(certificate, answer[1]) == "":
		seen = Certificates.from_pem(certificate.pem)
	if seen == null:
		_fail("the server at %s showed no certificate" % _address)
		return
	if _diagnosing and _pinned != null and Certificates.fingerprint(seen) == Certificates.fingerprint(_pinned):
		_fail("the server at %s did not finish the encrypted handshake" % _address)
		return
	var checked := KnownServers.check(_known, _address, _given, seen)
	if checked[1] != "":
		_fail(checked[1])
		return
	message = checked[0]
	_pinned = seen
	_diagnosing = false
	_dial_verified()


func _dial_probe() -> void:
	_stage = Stage.PROBE
	_asked = false
	_dial(Certificates.probe_options(), Certificates.COMMON_NAME)


func _dial_verified() -> void:
	_stage = Stage.VERIFIED
	_dial(Certificates.pinned_options(_pinned), Certificates.common_name(_pinned))


func _dial(options: TLSOptions, hostname: String) -> void:
	_started = ClientSession._now()
	var dialed: Variant = ENetTransport.dial(_address, options, hostname)
	if dialed is String:
		_fail(dialed)
		return
	_pending = dialed


func _fail(reason: String) -> void:
	error = reason
	_stage = Stage.FAILED
	_pending = null

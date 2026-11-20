extends TestCase
## The client's store of server certificates (ARCHITECTURE.md, 6.11): trust on
## first use, like the known hosts of SSH, and fingerprints given by hand.

## A certificate takes a while to make; the tests of this file share theirs.
static var _made: Array[X509Certificate] = []


static func _certificate(index: int) -> X509Certificate:
	while _made.size() <= index:
		_made.append(Certificates.generate()[0])
	return _made[index]


## _store opens a store in a fresh directory, removed after the test.
func _store() -> KnownServers:
	var dir := OS.get_user_data_dir().path_join("test-known-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	DirAccess.make_dir_recursive_absolute(dir)
	cleanup(func() -> void: _remove(dir))
	var loaded: Variant = KnownServers.load_file(dir.path_join("known_servers"))
	check(loaded is KnownServers, "a missing file did not load: %s" % [loaded])
	return loaded


static func _remove(dir: String) -> void:
	for sub in DirAccess.get_directories_at(dir):
		_remove(dir.path_join(sub))
	for file in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(file))
	DirAccess.remove_absolute(dir)


func _reload(known: KnownServers) -> KnownServers:
	var loaded: Variant = KnownServers.load_file(known.path)
	if loaded is String:
		fail(loaded)
		return KnownServers.new()
	return loaded


## The first connection remembers the certificate; later ones with it pass in
## silence, from the same store or after a restart.
func test_first_connection_is_trusted_and_remembered() -> void:
	var known := _store()
	var first := _certificate(0)
	var fingerprint := Certificates.fingerprint(first)
	check(Certificates.is_fingerprint(fingerprint), "fingerprint %s" % fingerprint)
	var result := KnownServers.check(known, "a.example:7777", "", first)
	check(result[1] == "" and "first connection" in result[0] and fingerprint in result[0], "the first connection: %s" % [result])
	check_equal(KnownServers.check(known, "a.example:7777", "", first), ["", ""], "the second connection")
	var again := _reload(known)
	check_equal(again.lookup("a.example:7777"), fingerprint, "the remembered fingerprint")
	var pinned := again.certificate(fingerprint)
	check(pinned != null and Certificates.fingerprint(pinned) == fingerprint, "the remembered certificate does not load")
	check_equal(KnownServers.check(again, "a.example:7777", "", first), ["", ""], "a connection after a restart")
	check_equal(again.lookup("b.example:7777"), "", "a server never joined")


## A server that shows another certificate than before is refused, with how to
## accept the new one.
func test_another_certificate_is_refused() -> void:
	var known := _store()
	KnownServers.check(known, "a.example:7777", "", _certificate(0))
	var other := Certificates.fingerprint(_certificate(1))
	var result := KnownServers.check(known, "a.example:7777", "", _certificate(1))
	check(result[1] != "" and "another certificate" in result[1] and other in result[1], "another certificate: %s" % [result])
	check_equal(_reload(known).lookup("a.example:7777"), Certificates.fingerprint(_certificate(0)), "the fingerprint after the refusal")


## A fingerprint given by the player must match, whatever is remembered; a
## matching one replaces the remembered one.
func test_given_fingerprint_decides() -> void:
	var known := _store()
	var first := Certificates.fingerprint(_certificate(0))
	var second := Certificates.fingerprint(_certificate(1))
	KnownServers.check(known, "a.example:7777", "", _certificate(0))
	var result := KnownServers.check(known, "a.example:7777", first, _certificate(1))
	check(result[1] != "" and "not the" in result[1], "a mismatched given fingerprint: %s" % [result])
	check_equal(KnownServers.check(known, "a.example:7777", first.to_upper(), _certificate(0)), ["", ""], "a matching given fingerprint in capitals")
	result = KnownServers.check(known, "a.example:7777", second, _certificate(1))
	check(result[1] == "" and "remembered" in result[0], "a given fingerprint for a new certificate: %s" % [result])
	check_equal(_reload(known).lookup("a.example:7777"), second, "the fingerprint after the new one was given")
	check_equal(KnownServers.check(_reload(known), "a.example:7777", "", _certificate(1)), ["", ""], "the next connection")


## Without a store the client says what it saw and how to pin it.
func test_no_store_remembers_nothing() -> void:
	var result := KnownServers.check(null, "a.example:7777", "", _certificate(0))
	check(result[1] == "" and "-fingerprint" in result[0], "without a store: %s" % [result])
	result = KnownServers.check(null, "a.example:7777", Certificates.fingerprint(_certificate(1)), _certificate(0))
	check(result[1] != "", "a mismatched given fingerprint without a store was accepted")


## A lost certificate file is written again; a broken store is refused.
func test_store_files() -> void:
	var known := _store()
	var fingerprint := Certificates.fingerprint(_certificate(0))
	KnownServers.check(known, "a.example:7777", "", _certificate(0))
	var file := known.path.get_base_dir().path_join("servers").path_join(fingerprint + ".crt")
	DirAccess.remove_absolute(file)
	check(known.certificate(fingerprint) == null, "a removed certificate still loads")
	check_equal(KnownServers.check(known, "a.example:7777", "", _certificate(0)), ["", ""], "a connection with the certificate file lost")
	check(known.certificate(fingerprint) != null, "the lost certificate was not written again")
	for bad in ["a.example:7777", "a.example:7777 12ab", "a.example:7777 %s extra" % fingerprint]:
		var broken := FileAccess.open(known.path, FileAccess.WRITE)
		broken.store_string("# comment\n\n%s\n" % bad)
		broken.close()
		check(KnownServers.load_file(known.path) is String, "the line %s was accepted" % bad)

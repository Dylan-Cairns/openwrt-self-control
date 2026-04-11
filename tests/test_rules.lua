local helper = require("test_helper")
local lu = require("luaunit")
local rules = require("quietwrt.rules")

TestRules = {}

function TestRules:test_normalize_url_input()
  local host = rules.normalize_host_input("HTTPS://User@www.Example.com:443/path?q=1")
  lu.assertEquals(host, "www.example.com")
end

function TestRules:test_reject_ip_input()
  local host, err = rules.normalize_host_input("8.8.8.8")
  lu.assertNil(host)
  lu.assertStrContains(err, "IP addresses")
end

function TestRules:test_workday_rejects_existing_always_host()
  local result = rules.apply_addition({ "example.com" }, {}, "workday", "example.com")
  lu.assertFalse(result.ok)
  lu.assertEquals(result.kind, "error")
  lu.assertStrContains(result.message, "already always blocked")
end

function TestRules:test_always_add_moves_from_workday()
  local result = rules.apply_addition({}, { "example.com" }, "always", "example.com")
  lu.assertTrue(result.ok)
  lu.assertEquals(result.always_hosts, { "example.com" })
  lu.assertEquals(result.workday_hosts, {})
  lu.assertStrContains(result.message, "Moved example.com")
end

function TestRules:test_compile_active_rules_respects_mode()
  local compiled = rules.compile_active_rules(
    { "always.com" },
    { "workday.com" },
    { "@@||allowed.com^" },
    { code = "always_only" }
  )

  lu.assertEquals(compiled, {
    "@@||allowed.com^",
    "||always.com^",
  })
end

function TestRules:test_partition_user_rules_preserves_passthrough()
  local always_hosts, passthrough_rules = rules.partition_user_rules({
    "||example.com^",
    "@@||allowed.com^",
    "# comment",
  })

  lu.assertEquals(always_hosts, { "example.com" })
  lu.assertEquals(passthrough_rules, {
    "@@||allowed.com^",
    "# comment",
  })
end

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

function TestRules:test_scheduled_lists_reject_existing_always_host()
  local result = rules.apply_addition({ "example.com" }, {
    workday = {},
    after_work = {},
  }, "workday", "example.com")
  lu.assertFalse(result.ok)
  lu.assertEquals(result.kind, "error")
  lu.assertStrContains(result.message, "already always blocked")
end

function TestRules:test_always_add_moves_from_workday()
  local result = rules.apply_addition({}, {
    workday = { "example.com" },
    after_work = {},
  }, "always", "example.com")
  lu.assertTrue(result.ok)
  lu.assertEquals(result.always_hosts, { "example.com" })
  lu.assertEquals(result.workday_hosts, {})
  lu.assertStrContains(result.message, "Moved example.com")
end

function TestRules:test_after_work_add_moves_from_workday()
  local result = rules.apply_addition({}, {
    workday = { "example.com" },
    after_work = {},
  }, "after_work", "example.com")
  lu.assertTrue(result.ok)
  lu.assertEquals(result.workday_hosts, {})
  lu.assertEquals(result.after_work_hosts, { "example.com" })
  lu.assertStrContains(result.message, "After work blocked")
end

function TestRules:test_password_vault_add_moves_from_after_work()
  local result = rules.apply_addition({}, {
    workday = {},
    after_work = { "example.com" },
    password_vault = {},
  }, "password_vault", "example.com")
  lu.assertTrue(result.ok)
  lu.assertEquals(result.after_work_hosts, {})
  lu.assertEquals(result.password_vault_hosts, { "example.com" })
  lu.assertStrContains(result.message, "Password vault blocked")
end

function TestRules:test_compile_active_rules_unions_always_and_scheduled_lists()
  local compiled = rules.compile_active_rules(
    { "always.com" },
    { "workday.com", "afterwork.com" },
    { "@@||allowed.com^" }
  )

  lu.assertEquals(compiled, {
    "@@||allowed.com^",
    "||afterwork.com^",
    "||always.com^",
    "||workday.com^",
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

function TestRules:test_load_hosts_file_requires_canonical_hostnames()
  local hosts, err = rules.load_hosts_file("Example.com\n", "always.txt")
  lu.assertNil(hosts)
  lu.assertStrContains(err, "canonical lowercase")
end

function TestRules:test_load_rules_file_rejects_block_rules()
  local parsed, err = rules.load_rules_file("||example.com^\n", "passthrough.txt")
  lu.assertNil(parsed)
  lu.assertStrContains(err, "passthrough")
end

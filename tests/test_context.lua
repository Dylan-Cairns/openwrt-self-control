local context_helpers = require("quietwrt.context")
local helper = require("test_helper")
local lu = require("luaunit")

TestContext = {}

function TestContext:test_write_atomic_rename_failure_keeps_existing_target()
  local fixture = helper.make_context()
  local target = helper.join_path(fixture.root, "AdGuardHome.yaml")
  helper.write_file(target, "original\n")

  fixture.env.rename_file = function()
    return false
  end

  local ok, err = context_helpers.write_atomic(fixture.env, target, "updated\n")

  lu.assertFalse(ok)
  lu.assertStrContains(err, "Could not replace")
  lu.assertEquals(helper.read_file(target), "original\n")
  fixture.cleanup()
end

function TestContext:test_with_lock_rejects_overlapping_mutation()
  local now = 1000
  local fixture = helper.make_context({
    time = function()
      return now
    end,
    sleep = function()
      now = now + 1
      return true
    end,
  })
  local context = {
    env = fixture.env,
    paths = fixture.paths,
  }
  local inner_ok
  local inner_error

  local outer_ok = context_helpers.with_lock(context, function()
    inner_ok, inner_error = context_helpers.with_lock(context, function()
      return true
    end, {
      timeout_seconds = 0,
    })
    return true
  end, {
    timeout_seconds = 0,
  })

  lu.assertTrue(outer_ok)
  lu.assertFalse(inner_ok)
  lu.assertStrContains(inner_error, "already applying")
  fixture.cleanup()
end


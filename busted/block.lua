local getfenv = require 'busted.compatibility'.getfenv
local unpack = require 'busted.compatibility'.unpack
local shuffle = require 'busted.utils'.shuffle

local function sort(elements)
  table.sort(elements, function(t1, t2)
    if t1.name and t2.name then
      return t1.name < t2.name
    end
    return t2.name ~= nil
  end)
  return elements
end

return function(busted)
  local block = {}

  function block.reject(descriptor, element)
    local env = getfenv(element.run)
    if env[descriptor] then
      element.env[descriptor] = function(...)
        error("'" .. descriptor .. "' not supported inside current context block", 2)
      end
    end
  end

  function block.rejectAll(element)
    block.reject('randomize', element)
    for descriptor, _ in pairs(busted.executors) do
      block.reject(descriptor, element)
    end
  end

  local function exec(descriptor, element)
    if not element.env then element.env = {} end

    block.rejectAll(element)

    local parent = busted.context.parent(element)
    setmetatable(element.env, {
      __newindex = function(self, key, value)
        if not parent.env then parent.env = {} end
        parent.env[key] = value
      end
    })

    local ret = { busted.safe(descriptor, element.run, element) }
    return unpack(ret)
  end

  function block.execAllOnce(descriptor, current, err)
    local parent = busted.context.parent(current)

    if parent then
      local success = block.execAllOnce(descriptor, parent)
      if not success then
        return success
      end
    end

    if not current[descriptor] then
      current[descriptor] = {}
    end
    local list = current[descriptor]
    if list.success ~= nil then
      return list.success
    end

    local success = true
    for _, v in ipairs(list) do
      if not exec(descriptor, v):success() then
        if err then err(descriptor) end
        success = false
      end
    end

    list.success = success

    return success
  end

  function block.execAll(descriptor, current, propagate, err)
    local parent = busted.context.parent(current)

    if propagate and parent then
      local success, ancestor = block.execAll(descriptor, parent, propagate)
      if not success then
        return success, ancestor
      end
    end

    local list = current[descriptor] or {}

    local success = true
    for _, v in ipairs(list) do
      if not exec(descriptor, v):success() then
        if err then err(descriptor) end
        success = nil
      end
    end
    return success, current
  end

  function block.dexecAll(descriptor, current, propagate, err)
    local parent = busted.context.parent(current)
    local list = current[descriptor] or {}

    local success = true
    for _, v in ipairs(list) do
      if not exec(descriptor, v):success() then
        if err then err(descriptor) end
        success = nil
      end
    end

    if propagate and parent then
      if not block.dexecAll(descriptor, parent, propagate) then
        success = nil
      end
    end
    return success
  end

  function block.lazySetup(element, err)
    return block.execAllOnce('lazy_setup', element, err)
  end

  function block.lazyTeardown(element, err)
    if element.lazy_setup and element.lazy_setup.success ~= nil then
      block.dexecAll('lazy_teardown', element, nil, err)
      element.lazy_setup.success = nil
    end
  end

  function block.setup(element, err)
      return block.execAll('strict_setup', element, nil, err)
  end

  function block.teardown(element, err)
      return block.dexecAll('strict_teardown', element, nil, err)
  end

  function block.execute(descriptor, element)
    if not element.env then element.env = {} end

    local randomize = busted.randomize
    element.env.randomize = function() randomize = true end

    if busted.safe(descriptor, element.run, element):success() then
      if randomize then
        element.randomseed = busted.randomseed
        shuffle(busted.context.children(element), busted.randomseed)
      elseif busted.sort then
        sort(busted.context.children(element))
      end

      if block.setup(element) then
        busted.execute(element)
      end

      block.lazyTeardown(element)
      block.teardown(element)
    end
  end

  return block
end

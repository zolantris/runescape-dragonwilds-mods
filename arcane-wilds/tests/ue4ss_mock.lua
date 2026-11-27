-- ArcaneWilds - UE4SS Runtime Mock Layer for Offline Lua Unit Tests
-- Provides safe stub implementations of UE4SS globals and mock UObjects so mod modules
-- can be imported and tested cleanly under standalone Lua 5.4 without launching the game.

local Mock = {
    ObjectsByPath = {},
    ObjectsByClass = {},
    Logs = {}
}

function Mock.MakeUObject(fullName, props)
    local obj = props or {}
    obj._fullName = fullName
    obj._valid = (obj._valid ~= false)
    function obj:IsValid()
        return self._valid == true
    end
    function obj:GetFullName()
        return self._fullName
    end
    function obj:GetAddress()
        return self._addr or tostring(self)
    end
    return obj
end

function Mock.RegisterPath(path, obj)
    Mock.ObjectsByPath[path] = obj
    return obj
end

function Mock.RegisterClassInstance(className, obj)
    Mock.ObjectsByClass[className] = Mock.ObjectsByClass[className] or {}
    table.insert(Mock.ObjectsByClass[className], obj)
    return obj
end

function Mock.Reset()
    Mock.ObjectsByPath = {}
    Mock.ObjectsByClass = {}
    Mock.Logs = {}
end

function Mock.InstallGlobals()
    _G.StaticFindObject = function(path)
        return Mock.ObjectsByPath[path]
    end
    _G.FindFirstOf = function(className)
        local list = Mock.ObjectsByClass[className]
        return list and list[1] or nil
    end
    _G.FindAllOf = function(className)
        return Mock.ObjectsByClass[className] or {}
    end
    _G.LoadAsset = function(path)
        return Mock.ObjectsByPath[path]
    end
    _G.StaticConstructObject = function(cls, outer)
        if Mock.OnStaticConstructObject then
            return Mock.OnStaticConstructObject(cls, outer)
        end
        return nil
    end
    _G.FName = function(s)
        return {
            _str = tostring(s or ""),
            ToString = function(self) return self._str end
        }
    end
    _G.FText = function(s)
        return { _text = tostring(s or "") }
    end
    _G.FString = function(s)
        return tostring(s or "")
    end
    _G.ExecuteInGameThread = function(fn)
        if type(fn) == "function" then fn() end
    end
    _G.ExecuteWithDelay = function(_, fn)
        if type(fn) == "function" then fn() end
    end
    _G.RegisterKeyBind = function() end
    _G.LoopAsync = function() end
    _G.NotifyOnNewObject = function() end
    _G.Key = {}
    _G.ModifierKey = { SHIFT = 1, CONTROL = 2, ALT = 4 }
end

return Mock

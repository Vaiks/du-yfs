local library = require("abstraction/Library")()
local json = require("builtin/dkjson")

local widget = {}
widget.__index = widget

local function new(panelId, title, unit)
    local instance = {
        panelId = panelId,
        title = title,
        unit = unit,
        widgetId = system.createWidget(panelId, "value"),
        dataId = nil
    }

    setmetatable(instance, widget)
    return instance
end

function widget:Close()
    system.removeDataFromWidget(self.dataId, self.widgetId)
    system.destroyData(self.dataId)
    system.destroyWidget(self.widgetId)
end

function widget:Set(value)
    local s = '{ "label":"' .. self.title .. '", "value": "' .. value .. '", "unit": "' .. self.unit .. '"}'

    if self.dataId == nil then
        system.destroyData(self.dataId)
        self.dataId = system.createData(s)
        system.addDataToWidget(self.dataId, self.widgetId)
    else
        system.updateData(self.dataId, s)
    end
end

return setmetatable(
    {
        new = new
    },
    {
        __call = function(_, ...)
            return new(...)
        end
    }
)

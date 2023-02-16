local log              = require("debug/Log")()
local RouteController  = require("flight/route/RouteController")
local BufferedDB       = require("storage/BufferedDB")
local FlightFSM        = require("flight/FlightFSM")
local FlightCore       = require("flight/FlightCore")
local SystemController = require("controller/SystemController")
local Settings         = require("Settings")
local floorDetector    = require("controller/FloorDetector").Instance()
local ver              = require("version_out")

log:SetLevel(log.LogLevel.WARNING)

local Task = require("system/Task")

local settingLink = library.getLinkByName("routes")
local routeLink = library.getLinkByName("routes")

if not settingLink or not routeLink then
    log:Error("Link databank named 'routes'")
    unit.exit()
end

local settingsDb = BufferedDB.New(settingLink)
local routeDb = BufferedDB.New(routeLink)
local settings = Settings.New(settingsDb)

Task.New("Main", function()
    log:Info(ver.APP_NAME)
    log:Info(ver.GIT_INFO, "/", ver.DATE_INFO)

    settingsDb.BeginLoad()
    routeDb.BeginLoad()

    while not settingsDb:IsLoaded() or not routeDb:IsLoaded() do
        coroutine.yield()
    end

    local rc = RouteController.Instance(routeDb)
    local fsm = FlightFSM.New(settings, rc)
    local fc = FlightCore.New(rc, fsm)
    fsm.SetFlightCore(fc)

    local cont = SystemController.New(fc, settings)
    settings.Reload()
    fc.ReceiveEvents()

    local floor = floorDetector.Measure()
    if not floor.Hit or floor.Distance > settings.Get("autoShutdownFloorDistance") then
        log:Info("No floor detected with set limit during startup, holding postition.")
        rc.ActivateHoldRoute()
        fc.StartFlight()
    else
        fsm.SetState(Idle.New(fsm))
    end
end).Then(function()
    log:Info("Ready.")
end).Catch(function(t)
    log:Error(t.Name(), t:Error())
end)

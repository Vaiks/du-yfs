local AxisControl = require("flight/AxisControl")
local Brakes = require("flight/Brakes")
local FlightFSM = require("flight/FlightFSM")
local EngineGroup = require("du-libs:abstraction/EngineGroup")
local Route = require("flight/route/Route")
local BufferedDB = require("du-libs:storage/BufferedDB")
local Waypoint = require("flight/route/Waypoint")
local vehicle = require("du-libs:abstraction/Vehicle")()
local visual = require("du-libs:debug/Visual")()
local library = require("du-libs:abstraction/Library")()
local sharedPanel = require("du-libs:panel/SharedPanel")()
local checks = require("du-libs:debug/Checks")
local alignment = require("flight/AlignmentFunctions")
local calc = require("du-libs:util/Calc")
local RouteController = require("flight/route/Controller")
local Vec3 = require("cpml/vec3")
local nullVec = Vec3()
local PointOptions = require("flight/route/PointOptions")
require("flight/state/Require")

local flightCore = {}
flightCore.__index = flightCore
local singleton

local defaultSpeed = 50 -- 50kph
local defaultMargin = 0.1 -- m

local routeDb = BufferedDB("routes")
routeDb:BeginLoad()

local function new()
    local instance = {
        ctrl = library:GetController(),
        routeController = RouteController(routeDb),
        brakes = Brakes(),
        thrustGroup = EngineGroup("thrust"),
        autoStabilization = nil,
        flushHandlerId = 0,
        updateHandlerId = 0,
        pitch = AxisControl(AxisControlPitch),
        roll = AxisControl(AxisControlRoll),
        yaw = AxisControl(AxisControlYaw),
        flightFSM = FlightFSM(),
        route = Route(routeDb),
        currentWaypoint = nil, -- The positions we want to move to
        previousWaypoint = nil, -- Previous waypoint
        waypointReachedSignaled = false,
        wWaypointDistance = sharedPanel:Get("Waypoint"):CreateValue("WP dist.", "m"),
        wWaypointMargin = sharedPanel:Get("Waypoint"):CreateValue("WP margin", "m"),
        wWaypointMaxSpeed = sharedPanel:Get("Waypoint"):CreateValue("WP max. s.", "m/s")
    }

    setmetatable(instance, flightCore)

    -- Setup start waypoints to prevent nil values
    instance.currentWaypoint = instance:CreateDefaultWP()
    instance.previousWaypoint = instance.currentWaypoint

    return instance
end

function flightCore:GetRoutController()
    return self.routeController
end

function flightCore:CreateDefaultWP()
    return Waypoint(vehicle.position.Current(), 0, 10, alignment.NoAdjust, alignment.NoAdjust)
end

function flightCore:NextWP()
    local route = self.routeController:CurrentRoute()

    if route == nil then
        return
    end

    local nextPoint = route:Next()
    if nextPoint == nil then
        return
    end

    self.previousWaypoint = self.currentWaypoint
    self.waypointReachedSignaled = false
    self.currentWaypoint = self:CreateWPFromPoint(nextPoint)
end

function flightCore:CreateWPFromPoint(point)
    local opt = point:Options()
    local dir = Vec3(opt:Get(PointOptions.LOCK_DIRECTION, nullVec))
    local margin = opt:Get(PointOptions.MARGIN, defaultMargin)
    local maxSpeed = opt:Get(PointOptions.MAX_SPEED, calc.Kph2Mps(defaultSpeed))

    local wp = Waypoint(point:Coordinate(), maxSpeed, margin, alignment.RollTopsideAwayFromVerticalReference, alignment.YawPitchKeepOrthogonalToVerticalReference)

    wp:SetPrecisionMode(opt:Get(PointOptions.PRECISION, false))

    if dir ~= nullVec then
        wp:LockDirection(dir)
    end

    return wp
end

function flightCore:StartFlight()
    local fsm = self.flightFSM

    self.waypointReachedSignaled = false

    -- Setup waypoint that will be the previous waypoint
    self.currentWaypoint = self:CreateDefaultWP()
    self:NextWP()

    -- Don't start unless we have a destination.
    if self.currentWaypoint then
        fsm:SetState(Travel(fsm))
    else
        fsm:SetState(Hold(fsm))
    end
end

-- Rotates all waypoints around the axis with the given angle
function flightCore:Turn(degrees, axis, rotationPoint)
    checks.IsNumber(degrees, "degrees", "flightCore:RotateWaypoints")
    checks.IsVec3(axis, "axis", "flightCore:RotateWaypoints")

    local currentWp = self.currentWaypoint
    if currentWp then
        rotationPoint = (rotationPoint or vehicle.position.Current())

        -- Find new direction
        local direction = vehicle.orientation.Forward()
        direction = calc.RotateAroundAxis(direction, nullVec, degrees, axis)

        currentWp:LockDirection(direction, true)
    end
end

function flightCore:SetNormalMode()
    self.flightFSM:SetNormalMode()
end

function flightCore:SetPrecisionMode()
    self.flightFSM:SetPrecisionMode()
end

function flightCore:ReceiveEvents()
    self.flushHandlerId = system:onEvent("onFlush", self.FCFlush, self)
    self.updateHandlerId = system:onEvent("onUpdate", self.FCUpdate, self)
    self.pitch:ReceiveEvents()
    self.roll:ReceiveEvents()
    self.yaw:ReceiveEvents()
end

function flightCore:StopEvents()
    system:clearEvent("flush", self.flushHandlerId)
    system:clearEvent("update", self.updateHandlerId)
    self.pitch:StopEvents()
    self.roll:StopEvents()
    self.yaw:StopEvents()
end

function flightCore:Align()
    local waypoint = self.currentWaypoint
    local prev = self.previousWaypoint

    local target = waypoint:YawAndPitch(prev)

    if target ~= nil then
        visual:DrawNumber(6, target + vehicle.orientation.Forward() * 1)
        self.yaw:SetTarget(target)
        self.pitch:SetTarget(target)
    else
        self.yaw:Disable()
        self.pitch:Disable()
    end

    local topSideAlignment = waypoint:Roll(prev)
    if topSideAlignment ~= nil then
        self.roll:SetTarget(topSideAlignment)
    else
        self.roll:Disable()
    end
end

function flightCore:FCUpdate()
    local status, err, _ = xpcall(
            function()
                self.flightFSM:Update()
                self.brakes:BrakeUpdate()

                local wp = self.currentWaypoint
                if wp ~= nil then
                    self.wWaypointDistance:Set(calc.Round(wp:DistanceTo(), 3))
                    self.wWaypointMargin:Set(calc.Round(wp.margin, 3))
                    self.wWaypointMaxSpeed:Set(wp.maxSpeed)

                    local diff = wp.destination - self.previousWaypoint.destination
                    local len = diff:len()
                    local dir = diff:normalize()
                    visual:DrawNumber(1, self.previousWaypoint.destination)
                    visual:DrawNumber(2, self.previousWaypoint.destination + dir * len / 4)
                    visual:DrawNumber(3, self.previousWaypoint.destination + dir * len / 2)
                    visual:DrawNumber(4, self.previousWaypoint.destination + dir * 3 * len / 4)
                    visual:DrawNumber(5, wp.destination)
                end
            end,
            traceback
    )

    if not status then
        system.print(err)
        unit.exit()
    end
end

function flightCore:FCFlush()
    local status, err, _ = xpcall(
            function()
                local route = self.routeController:CurrentRoute()
                local wp = self.currentWaypoint

                if wp and route then
                    if wp:Reached() then
                        if not self.waypointReachedSignaled then
                            self.waypointReachedSignaled = true
                            self.flightFSM:WaypointReached(route:LastPointReached(), wp, self.previousWaypoint)

                            wp:LockDirection(vehicle.orientation.Forward())
                        end

                        -- Switch to next waypoint
                        self:NextWP()
                    else
                        -- When we go out of range, reset signal so that we get it again when we're back on the waypoint.
                        self.waypointReachedSignaled = false
                    end

                    self:Align()
                    self.flightFSM:FsmFlush(self.currentWaypoint, self.previousWaypoint)
                end

                self.pitch:AxisFlush(false)
                self.roll:AxisFlush(false)
                self.yaw:AxisFlush(true)
                self.brakes:BrakeFlush()
            end,
            traceback
    )

    if not status then
        system.print(err)
        unit.exit()
    end
end

-- The module
return setmetatable(
        {
            new = new
        },
        {
            __call = function(_, ...)
                if singleton == nil then
                    singleton = new()
                end
                return singleton
            end
        }
)
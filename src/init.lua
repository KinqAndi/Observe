--[[
	Author @KinqAndi
	Date @09/01/23
	Version: 1.0.3

    Description: Observe is useful in cases where objects are not streamed in/added.
]]

local Dumpster = require(script.Parent.Dumpster)
local Promise = require(script.Parent.Promise)

local Observe = {}

--[=[
	@return Promise
	Observes a path from an object that is either an instance or a dictionary table.

	Paremeters
        - object: Instance | {[any]: any},
        - path: string
        - timeout: will reject if object not found after timeout has passed
        - customPathSeperator: string? this will change the way your path is interpreted.

		```lua
			-- Here we have no timeout, and no custom path seperator (DEFAULT IS .)
			Observe(workspace, "MyBase.SpawnLocation"):andThen(function(mySpawnLocation)
				warn(mySpawnLocation)
			end)
		```

        OR

		```lua
			-- here we pass in 10 seconds for timeout, as well as a path seperator "/"
			--after 10 seconds, if object could not be found, it will be rejected.
			Observe(workspace, "MyBase/SpawnLocation", 10, "/"):andThen(function(mySpawnLocation)
				warn(mySpawnLocation)
			end)
		```
]=]

function Observe.Get(object: Instance | {[any]: any}, path: string, timeout: number?, customPathSeperator: string?)
	local dumpster = Dumpster.new()

	local promise = Promise.new(function(resolve, reject, onCancel)
		local typeOfObject, typeOfPath, typeOfTimeout, typeOfCustomPathSeperator = typeof(object), typeof(path), typeof(timeout), typeof(customPathSeperator)

		if typeOfPath ~= "string" then
			return reject(`Observe is expecing path as a string but {typeOfPath} was provided!`)
		end

		if timeout and (typeOfTimeout ~= "number") then
			return reject(`Observe is expecing timeout as a number but {typeOfTimeout} was provided!`)
		end

		if customPathSeperator and (typeOfCustomPathSeperator ~= "string") then
			return reject(`Observe is expecting customPathSeperator as a string but {typeOfCustomPathSeperator} was provided!`)
		end

		if not (typeOfObject == "Instance" or typeOfObject == "table") then
			return reject(`Observe is expecting object as Instance | table but {typeOfObject} was provided!`)
		end

		typeOfObject =nil
		typeOfPath = nil
		typeOfTimeout = nil
		typeOfCustomPathSeperator = nil

		path = Observe:_turnStringedPathIntoTable(path, customPathSeperator)

		onCancel(function(...)
			dumpster:Destroy()
		end)

		local currentIndex: number = 1
		local currentObject = object

		local streamDumpster = dumpster:Extend()

		--will attempt to recursively find the targeted instance
		local function recurseFindForInstance()
			if not dumpster then
				return
			end

			if not path[currentIndex] then
				return resolve(currentObject)
			end

			local childExists = currentObject:FindFirstChild(path[currentIndex])

			if childExists then
				currentObject = childExists
				currentIndex += 1
				return recurseFindForInstance()
			else
				streamDumpster:Add(currentObject.ChildAdded:Connect(function(child)
					if child.Name == path[currentIndex] then
						streamDumpster:Destroy()
						currentIndex += 1
						currentObject = child
						recurseFindForInstance()
					else
						streamDumpster:Add(child:GetPropertyChangedSignal("Name"):Connect(function()
							if child.Name == path[currentIndex] then
								streamDumpster:Destroy()
								currentIndex += 1
								currentObject = child
								recurseFindForInstance()
							end
						end))
					end
				end))

				for _, part in currentObject:GetChildren() do
					streamDumpster:Add(part:GetPropertyChangedSignal("Name"):Connect(function()
						if part.Name == path[currentIndex] then
							streamDumpster:Destroy()
							currentIndex += 1
							currentObject = part
							recurseFindForInstance()
						end
					end))
				end
			end
		end

		--
		local function recurseFindForTable()
			if not dumpster then
				return
			end

			local currentPathId = path[currentIndex]

			if not currentPathId then
				return resolve(currentObject)
			end

			if typeof(currentObject) == "table" then
				streamDumpster:Add(game:GetService("RunService").Heartbeat:Connect(function()
					if currentObject[currentPathId] then
						currentObject = currentObject[currentPathId] 
						currentIndex += 1
						streamDumpster:Destroy()
						recurseFindForTable()
					end
				end))
			elseif typeof(currentObject) == "Instance" then
				streamDumpster:Destroy()
				recurseFindForInstance()
			else
				return resolve(currentObject)
			end
		end

		local typeOf = typeof(object)

		if typeOf == "Instance" then
			recurseFindForInstance()
		elseif typeOf == "table" then
			recurseFindForTable()
		end
	end)

	--cleanup references
	dumpster:Add(function()
		promise = nil
		dumpster = nil
	end)

	--if the promise has just been initialized, we can add it to the dumpster for gc.
	if promise.Status == Promise.Status.Started then
		dumpster:AddPromise(promise)
	end

	--incase promise was rejected before it reached the cleanup function.
	if promise.Status == Promise.Status.Cancelled or promise.Status == Promise.Status.Rejected or promise.Status == Promise.Status.Resolved then
		dumpster:Destroy()
	end

	if timeout then
		promise = promise:timeout(timeout)
	end

	--returns promise with instance.
	return promise:andThen(function(...)
		dumpster:Destroy()
		return ...
	end):catch(function(...)
		dumpster:Destroy()
		return Promise.reject(...)
	end)
end

--[=[
	@return Promise
	Observes a path from an object that is either an instance or a dictionary table. The final object in the path must be a model, otherwise it is rejected.
	If final object in path is indeed a model, it will start observing for when a primary part is added to it, then and only then it will resolve.

	Paremeters
        - object: Instance | {[any]: any},
        - path: string
        - timeout: will reject if object not found after timeout has passed
        - customPathSeperator: string? this will change the way your path is interpreted.

		```lua
			Observe.PrimaryPart(workspace, "KinqAndi"):andThen(function(myRootPart)
				warn(myRootPart)
			end)
		```
]=]

function Observe.PrimaryPart(object: Instance, path: string, timeout: number?, customPathSeperator: string?)
	return Observe.Get(object, path, timeout, customPathSeperator):andThen(function(object)
		if not object:IsA("Model") then
			return Promise.reject(`Could not retrieve primary part since {object.Name} is not a model! \n{debug.traceback()}`)
		end

		if object.PrimaryPart then
			return object.PrimaryPart
		end

		local newPromise = Promise.fromEvent(object:GetPropertyChangedSignal("PrimaryPart"), function()
			return true
		end):andThen(function()
			return object.PrimaryPart
		end)

		if timeout then
			newPromise = newPromise:timeout(timeout)
		end

		return newPromise
	end)
end

--[=[
	@return Promise
	Observes descendants and checks if name is matching the object name.

	Paremeters
        - parentObject: Instance
        - objectName: string
        - timeout:number?
        - className: string?

		```lua
			Observe.Descendant(workspace, "Decal"):andThen(function(decal)
				warn(decal)
			end)
		```
]=]

function Observe.Descendant(parentObject: Instance, objectName: string, timeout: number, className: string?)
	local dumpster = Dumpster.new()

	local promise = Promise.new(function(resolve, reject, onCancel)
		onCancel(function(...)
			dumpster:Destroy()
		end)

		if typeof(parentObject) ~= "Instance" then
			return reject(`Observe is expecing a instance for the object but {typeof(parentObject)} was provided!`)
		end

		if typeof(objectName) ~= "string" then
			return reject(`Observe is expecing a string for objectName but {typeof(objectName)} was provided!`)
		end

		if timeout and typeof(timeout) ~= "number" then
			return reject(`Observe is expecing a number for timeout but {typeof(timeout)} was provided!`)
		end

		if className and typeof(className) ~= "string" then
			return reject(`Observe is expecing a string for className but {typeof(className)} was provided!`)
		end

		for _, desc: Instance in parentObject:GetDescendants() do
			if desc.Name == objectName then
				if className and (desc.ClassName ~= className) then
					continue
				end

				return resolve(desc)
			end
		end

		dumpster:Add(parentObject.DescendantAdded:Connect(function(desc)
			if desc.Name == objectName then
				if className and (desc.ClassName ~= className) then
					return
				end

				return resolve(desc)
			end
		end))
	end)

	if timeout then
		promise = promise:timeout(timeout)
	end

	--if the promise has just been initialized, we can add it to the dumpster for gc.
	if promise.Status == Promise.Status.Started then
		dumpster:AddPromise(promise)
	end

	--incase promise was rejected before it reached the cleanup function.
	if promise.Status == Promise.Status.Cancelled or promise.Status == Promise.Status.Rejected or promise.Status == Promise.Status.Resolved then
		dumpster:Destroy()
	end

	--returns promise with instance.
	return promise:andThen(function(...)
		dumpster:Destroy()
		return ...
	end):catch(function(...)
		dumpster:Destroy()
		return Promise.reject(...)
	end)
end

--[=[
	@return Promise
	Creates a super observer that will keep watching each observer passed
    once every observer has been resolved, the main observer will.

    If any fail to resolve, the whole thing will fail.

	Paremeters
		... : Promise

	```lua
		local spawnLocationObserver = Observe(workspace, "MyBase.SpawnLocation")
		local myRootPartObserver = Observe.PrimaryPart(workspace, "KinqAndi")

		Observe.Bulk(spawnLocationObserver, myRootPartObserver):andThen(function(spawnLocation, hrp)
			hrp:PivotTo(spawnLocation:GetPivot())
		end)
	```
]=]

function Observe.Bulk(...)
	local chains = {...}

	return Promise.new(function(resolve, reject)
		local returnValues = {}

		for _, chain in chains do
			local success, result = chain:await()

			if not success then
				return reject(`One or more Observes has been rejected! \n{result}`)
			end

			table.insert(returnValues, result)
		end

		return resolve(table.unpack(returnValues))
	end)
end

--------------------------- PRIVATE METHODS ---------------------------------
--returns path as a string
function Observe:_turnPathIntoString(parent, path, customPathSeperator: string?)
	return `{if typeof(parent) == "table" then parent else parent.Name}.{table.concat(path, `{customPathSeperator or "."}`)}`
end

--turns a stringed path into a list.
function Observe:_turnStringedPathIntoTable(strPath: string, customSeperator: string?)
	customSeperator = customSeperator or "."
	return string.split(strPath, customSeperator)
end

--
return setmetatable(Observe, {
	__call = function(self,...)
		return self.Get(...)
	end,
})
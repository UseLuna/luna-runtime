--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.Luna.Packages.jest_globals)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect

local AnimationData = require(ReplicatedStorage.Luna.Core.AnimationData)
local Importer = require(ReplicatedStorage.Luna.Solver.Importer)
local Exporter = require(ReplicatedStorage.Luna.Solver.Exporter)
local Evaluator = require(ReplicatedStorage.Luna.Core.Evaluator)
local TestHelpers = require(ReplicatedStorage.Tests.TestHelpers)

-- Helper: build a minimal KeyframeSequence programmatically
local function MakeKFS(Config: {
	Name: string?,
	Loop: boolean?,
	Priority: Enum.AnimationPriority?,
	Keyframes: {
		{
			Time: number,
			Poses: {
				{
					Name: string,
					CFrame: CFrame,
					Weight: number?,
					EasingStyle: Enum.PoseEasingStyle?,
					EasingDirection: Enum.PoseEasingDirection?,
					Children: any?,
				}
			},
		}
	},
}): KeyframeSequence
	local KFS = Instance.new("KeyframeSequence")
	KFS.Name = Config.Name or "TestAnim"
	KFS.Loop = if Config.Loop ~= nil then Config.Loop else false
	KFS.Priority = Config.Priority or Enum.AnimationPriority.Action

	for _, KfData in Config.Keyframes do
		local Kf = Instance.new("Keyframe")
		Kf.Time = KfData.Time

		-- Build a flat root pose containing all joints as sub-poses
		local RootPose = Instance.new("Pose")
		RootPose.Name = "HumanoidRootPart"
		RootPose.Weight = 0

		for _, PoseData in KfData.Poses do
			local PoseInst = Instance.new("Pose")
			PoseInst.Name = PoseData.Name
			PoseInst.CFrame = PoseData.CFrame
			PoseInst.Weight = PoseData.Weight or 1
			if PoseData.EasingStyle then
				PoseInst.EasingStyle = PoseData.EasingStyle
			end
			if PoseData.EasingDirection then
				PoseInst.EasingDirection = PoseData.EasingDirection
			end
			-- Support nested children
			if PoseData.Children then
				for _, ChildData in PoseData.Children do
					local ChildPose = Instance.new("Pose")
					ChildPose.Name = ChildData.Name
					ChildPose.CFrame = ChildData.CFrame
					ChildPose.Weight = ChildData.Weight or 1
					if ChildData.EasingStyle then
						ChildPose.EasingStyle = ChildData.EasingStyle
					end
					PoseInst:AddSubPose(ChildPose)
				end
			end
			RootPose:AddSubPose(PoseInst)
		end

		Kf:AddPose(RootPose)
		KFS:AddKeyframe(Kf)
	end

	return KFS
end

describe("Importer", function()
	describe("Registry", function()
		it("has KeyframeSequence adapter registered", function()
			local Names = Importer.GetAdapterNames()
			local HasKFS = false
			for _, Name in Names do
				if Name == "KeyframeSequence" then
					HasKFS = true
				end
			end
			expect(HasKFS).toBe(true)
		end)

		it("throws for unknown adapter", function()
			expect(function()
				Importer.Import("NonexistentFormat", nil)
			end).toThrowError()
		end)
	end)

	describe("KeyframeSequence Import", function()
		it("imports empty KFS", function()
			local KFS = Instance.new("KeyframeSequence")
			KFS.Name = "Empty"
			local Result = Importer.Import("KeyframeSequence", KFS)
			expect(Result).toBeDefined()
			if Result then
				expect(Result.Name).toBe("Empty")
				expect(#Result.Tracks).toBe(0)
			end
			KFS:Destroy()
		end)

		it("imports single track with 2 keyframes", function()
			local KFS = MakeKFS({
				Name = "Simple",
				Keyframes = {
					{ Time = 0, Poses = { { Name = "Arm", CFrame = CFrame.identity } } },
					{ Time = 1, Poses = { { Name = "Arm", CFrame = CFrame.new(5, 0, 0) } } },
				},
			})

			local Result = Importer.Import("KeyframeSequence", KFS)
			expect(Result).toBeDefined()
			if Result then
				expect(#Result.Tracks).toBe(1)
				expect(Result.Tracks[1].Name).toBe("Arm")
				expect(#Result.Tracks[1].Channels.PositionX.Keyframes).toBe(2)
				expect(Result.Tracks[1].Channels.PositionX.Keyframes[2].Value).toBeCloseTo(5, 2)
			end
			KFS:Destroy()
		end)

		it("imports multiple tracks", function()
			local KFS = MakeKFS({
				Keyframes = {
					{
						Time = 0,
						Poses = {
							{ Name = "Arm", CFrame = CFrame.identity },
							{ Name = "Leg", CFrame = CFrame.identity },
							{ Name = "Head", CFrame = CFrame.identity },
						},
					},
					{
						Time = 1,
						Poses = {
							{ Name = "Arm", CFrame = CFrame.new(1, 0, 0) },
							{ Name = "Leg", CFrame = CFrame.new(0, 1, 0) },
							{ Name = "Head", CFrame = CFrame.new(0, 0, 1) },
						},
					},
				},
			})

			local Result = Importer.Import("KeyframeSequence", KFS)
			expect(Result).toBeDefined()
			if Result then
				expect(#Result.Tracks).toBe(3)
			end
			KFS:Destroy()
		end)

		it("preserves Loop flag", function()
			local KFS = MakeKFS({
				Loop = true,
				Keyframes = { { Time = 0, Poses = { { Name = "A", CFrame = CFrame.identity } } } },
			})
			local Result = Importer.Import("KeyframeSequence", KFS)
			expect(Result).toBeDefined()
			if Result then
				expect(Result.Looping).toBe(true)
			end
			KFS:Destroy()
		end)

		it("maps Core priority", function()
			local KFS = MakeKFS({
				Priority = Enum.AnimationPriority.Core,
				Keyframes = { { Time = 0, Poses = { { Name = "A", CFrame = CFrame.identity } } } },
			})
			local Result = Importer.Import("KeyframeSequence", KFS)
			if Result then
				expect(Result.Priority).toBe(0)
			end
			KFS:Destroy()
		end)

		it("maps Action4 priority", function()
			local KFS = MakeKFS({
				Priority = Enum.AnimationPriority.Action4,
				Keyframes = { { Time = 0, Poses = { { Name = "A", CFrame = CFrame.identity } } } },
			})
			local Result = Importer.Import("KeyframeSequence", KFS)
			if Result then
				expect(Result.Priority).toBe(6)
			end
			KFS:Destroy()
		end)

		it("computes Duration from last keyframe", function()
			local KFS = MakeKFS({
				Keyframes = {
					{ Time = 0, Poses = { { Name = "A", CFrame = CFrame.identity } } },
					{ Time = 2.5, Poses = { { Name = "A", CFrame = CFrame.new(1, 0, 0) } } },
				},
			})
			local Result = Importer.Import("KeyframeSequence", KFS)
			if Result then
				expect(Result.Duration).toBeCloseTo(2.5)
			end
			KFS:Destroy()
		end)

		it("skips Weight=0 poses", function()
			local KFS = MakeKFS({
				Keyframes = {
					{
						Time = 0,
						Poses = {
							{ Name = "HierarchyOnly", CFrame = CFrame.identity, Weight = 0 },
							{ Name = "Animated", CFrame = CFrame.new(1, 0, 0), Weight = 1 },
						},
					},
				},
			})
			local Result = Importer.Import("KeyframeSequence", KFS)
			if Result then
				expect(#Result.Tracks).toBe(1)
				expect(Result.Tracks[1].Name).toBe("Animated")
			end
			KFS:Destroy()
		end)

		it("imports nested Pose hierarchy", function()
			local KFS = MakeKFS({
				Keyframes = {
					{
						Time = 0,
						Poses = {
							{
								Name = "UpperTorso",
								CFrame = CFrame.identity,
								Weight = 1,
								Children = {
									{ Name = "Head", CFrame = CFrame.Angles(0, math.rad(30), 0), Weight = 1 },
								},
							},
						},
					},
				},
			})
			local Result = Importer.Import("KeyframeSequence", KFS)
			if Result then
				expect(#Result.Tracks).toBe(2)
				-- Both UpperTorso and Head should be imported
				local Names: { [string]: boolean } = {}
				for _, Track in Result.Tracks do
					Names[Track.Name] = true
				end
				expect(Names["UpperTorso"]).toBe(true)
				expect(Names["Head"]).toBe(true)
			end
			KFS:Destroy()
		end)

		it("handles sparse poses (joint only at some keyframes)", function()
			local KFS = MakeKFS({
				Keyframes = {
					{
						Time = 0,
						Poses = {
							{ Name = "Arm", CFrame = CFrame.identity },
							{ Name = "Leg", CFrame = CFrame.identity },
						},
					},
					{ Time = 1, Poses = { { Name = "Arm", CFrame = CFrame.new(5, 0, 0) } } }, -- Leg missing
					{
						Time = 2,
						Poses = {
							{ Name = "Arm", CFrame = CFrame.identity },
							{ Name = "Leg", CFrame = CFrame.new(0, 3, 0) },
						},
					},
				},
			})
			local Result = Importer.Import("KeyframeSequence", KFS)
			if Result then
				local ArmTrack, LegTrack
				for _, Track in Result.Tracks do
					if Track.Name == "Arm" then
						ArmTrack = Track
					end
					if Track.Name == "Leg" then
						LegTrack = Track
					end
				end
				expect(ArmTrack).toBeDefined()
				expect(LegTrack).toBeDefined()
				if ArmTrack and LegTrack then
					expect(#ArmTrack.Channels.PositionX.Keyframes).toBe(3)
					expect(#LegTrack.Channels.PositionX.Keyframes).toBe(2) -- Only at t=0 and t=2
				end
			end
			KFS:Destroy()
		end)
	end)

	describe("Easing Import", function()
		it("Linear easing → Linear curve", function()
			local KFS = MakeKFS({
				Keyframes = {
					{
						Time = 0,
						Poses = { { Name = "A", CFrame = CFrame.identity, EasingStyle = Enum.PoseEasingStyle.Linear } },
					},
					{ Time = 1, Poses = { { Name = "A", CFrame = CFrame.new(1, 0, 0) } } },
				},
			})
			local Result = Importer.Import("KeyframeSequence", KFS)
			if Result then
				expect(Result.Tracks[1].Channels.PositionX.Keyframes[1].Interpolation.Curve).toBe("Linear")
			end
			KFS:Destroy()
		end)

		it("Constant easing → Stepped curve", function()
			local KFS = MakeKFS({
				Keyframes = {
					{
						Time = 0,
						Poses = {
							{ Name = "A", CFrame = CFrame.identity, EasingStyle = Enum.PoseEasingStyle.Constant },
						},
					},
					{ Time = 1, Poses = { { Name = "A", CFrame = CFrame.new(1, 0, 0) } } },
				},
			})
			local Result = Importer.Import("KeyframeSequence", KFS)
			if Result then
				expect(Result.Tracks[1].Channels.PositionX.Keyframes[1].Interpolation.Curve).toBe("Stepped")
			end
			KFS:Destroy()
		end)

		it("CubicV2 + In → Easing Cubic In", function()
			local KFS = MakeKFS({
				Keyframes = {
					{
						Time = 0,
						Poses = {
							{
								Name = "A",
								CFrame = CFrame.identity,
								EasingStyle = Enum.PoseEasingStyle.CubicV2,
								EasingDirection = Enum.PoseEasingDirection.In,
							},
						},
					},
					{ Time = 1, Poses = { { Name = "A", CFrame = CFrame.new(1, 0, 0) } } },
				},
			})
			local Result = Importer.Import("KeyframeSequence", KFS)
			if Result then
				local Interp = Result.Tracks[1].Channels.PositionX.Keyframes[1].Interpolation
				expect(Interp.Curve).toBe("Easing")
				expect(Interp.EasingStyle).toBe("Cubic")
				expect(Interp.EasingDirection).toBe("In")
			end
			KFS:Destroy()
		end)

		it("CubicV2 + Out → Easing Cubic Out", function()
			local KFS = MakeKFS({
				Keyframes = {
					{
						Time = 0,
						Poses = {
							{
								Name = "A",
								CFrame = CFrame.identity,
								EasingStyle = Enum.PoseEasingStyle.CubicV2,
								EasingDirection = Enum.PoseEasingDirection.Out,
							},
						},
					},
					{ Time = 1, Poses = { { Name = "A", CFrame = CFrame.new(1, 0, 0) } } },
				},
			})
			local Result = Importer.Import("KeyframeSequence", KFS)
			if Result then
				local Interp = Result.Tracks[1].Channels.PositionX.Keyframes[1].Interpolation
				expect(Interp.EasingDirection).toBe("Out")
			end
			KFS:Destroy()
		end)

		it("CubicV2 + InOut → Easing Cubic InOut", function()
			local KFS = MakeKFS({
				Keyframes = {
					{
						Time = 0,
						Poses = {
							{
								Name = "A",
								CFrame = CFrame.identity,
								EasingStyle = Enum.PoseEasingStyle.CubicV2,
								EasingDirection = Enum.PoseEasingDirection.InOut,
							},
						},
					},
					{ Time = 1, Poses = { { Name = "A", CFrame = CFrame.new(1, 0, 0) } } },
				},
			})
			local Result = Importer.Import("KeyframeSequence", KFS)
			if Result then
				local Interp = Result.Tracks[1].Channels.PositionX.Keyframes[1].Interpolation
				expect(Interp.EasingDirection).toBe("InOut")
			end
			KFS:Destroy()
		end)

		it("Bounce + Out → Easing Bounce Out", function()
			local KFS = MakeKFS({
				Keyframes = {
					{
						Time = 0,
						Poses = {
							{
								Name = "A",
								CFrame = CFrame.identity,
								EasingStyle = Enum.PoseEasingStyle.Bounce,
								EasingDirection = Enum.PoseEasingDirection.Out,
							},
						},
					},
					{ Time = 1, Poses = { { Name = "A", CFrame = CFrame.new(1, 0, 0) } } },
				},
			})
			local Result = Importer.Import("KeyframeSequence", KFS)
			if Result then
				local Interp = Result.Tracks[1].Channels.PositionX.Keyframes[1].Interpolation
				expect(Interp.Curve).toBe("Easing")
				expect(Interp.EasingStyle).toBe("Bounce")
				expect(Interp.EasingDirection).toBe("Out")
			end
			KFS:Destroy()
		end)

		it("Elastic + InOut → Easing Elastic InOut", function()
			local KFS = MakeKFS({
				Keyframes = {
					{
						Time = 0,
						Poses = {
							{
								Name = "A",
								CFrame = CFrame.identity,
								EasingStyle = Enum.PoseEasingStyle.Elastic,
								EasingDirection = Enum.PoseEasingDirection.InOut,
							},
						},
					},
					{ Time = 1, Poses = { { Name = "A", CFrame = CFrame.new(1, 0, 0) } } },
				},
			})
			local Result = Importer.Import("KeyframeSequence", KFS)
			if Result then
				local Interp = Result.Tracks[1].Channels.PositionX.Keyframes[1].Interpolation
				expect(Interp.Curve).toBe("Easing")
				expect(Interp.EasingStyle).toBe("Elastic")
				expect(Interp.EasingDirection).toBe("InOut")
			end
			KFS:Destroy()
		end)

		it("Deprecated Cubic enum treated same as CubicV2", function()
			local KFS = MakeKFS({
				Keyframes = {
					{
						Time = 0,
						Poses = {
							{
								Name = "A",
								CFrame = CFrame.identity,
								EasingStyle = Enum.PoseEasingStyle.Cubic,
								EasingDirection = Enum.PoseEasingDirection.In,
							},
						},
					},
					{ Time = 1, Poses = { { Name = "A", CFrame = CFrame.new(1, 0, 0) } } },
				},
			})
			local Result = Importer.Import("KeyframeSequence", KFS)
			if Result then
				local Interp = Result.Tracks[1].Channels.PositionX.Keyframes[1].Interpolation
				expect(Interp.Curve).toBe("Easing")
				expect(Interp.EasingStyle).toBe("Cubic")
			end
			KFS:Destroy()
		end)
	end)

	describe("Round-Trip", function()
		it("EditAnimation → baked KFS → import produces same poses", function()
			local Edit = AnimationData.CreateEmptyAnimation("RoundTrip", 2)
			local Track = AnimationData.CreateEmptyTrack("Arm")
			AnimationData.AddKeyframe(Track, 0, CFrame.new(0, 0, 0))
			AnimationData.AddKeyframe(Track, 1, CFrame.new(5, 3, 0) * CFrame.Angles(0, math.rad(45), 0))
			AnimationData.AddKeyframe(Track, 2, CFrame.new(0, 0, 0))
			table.insert(Edit.Tracks, Track)

			-- Export to KFS (need joints for hierarchy — use minimal joint list)
			local Joints = { { Name = "Arm", Part0Name = "HumanoidRootPart", Part1Name = "Arm" } }
			local KFS = Exporter.ExportAnimationBaked("KeyframeSequence", Edit, Joints)
			expect(KFS).toBeDefined()
			if not KFS then
				return
			end

			-- Import back
			local Imported = Importer.Import("KeyframeSequence", KFS)
			expect(Imported).toBeDefined()
			if not Imported then
				KFS:Destroy()
				return
			end

			-- Compile both and evaluate at t=1
			local OriginalRuntime = AnimationData.CompileEditToRuntime(Edit)
			local ImportedRuntime = AnimationData.CompileEditToRuntime(Imported)
			local OriginalPose = Evaluator.EvaluateAnimation(OriginalRuntime, 1)
			local ImportedPose = Evaluator.EvaluateAnimation(ImportedRuntime, 1)

			-- Compare (wider tolerance due to Euler round-trip)
			expect(OriginalPose["Arm"]).toBeDefined()
			expect(ImportedPose["Arm"]).toBeDefined()
			if OriginalPose["Arm"] and ImportedPose["Arm"] then
				expect(TestHelpers.CFrameComponentsClose(OriginalPose["Arm"], ImportedPose["Arm"], 1e-2)).toBe(true)
			end
			KFS:Destroy()
		end)

		it("round-trip preserves mixed easing styles", function()
			local Edit = AnimationData.CreateEmptyAnimation("MixedEasing", 2)

			local LinearTrack = AnimationData.CreateEmptyTrack("LinearArm")
			AnimationData.AddKeyframe(LinearTrack, 0, CFrame.identity)
			AnimationData.AddKeyframe(LinearTrack, 2, CFrame.new(5, 0, 0))
			table.insert(Edit.Tracks, LinearTrack)

			local SteppedTrack = AnimationData.CreateEmptyTrack("SteppedLeg")
			AnimationData.AddKeyframe(SteppedTrack, 0, CFrame.identity, {
				Curve = "Stepped",
				EasingStyle = nil,
				EasingDirection = nil,
				LeftHandle = nil,
				RightHandle = nil,
				HandleType = nil,
			})
			AnimationData.AddKeyframe(SteppedTrack, 2, CFrame.new(0, 3, 0))
			table.insert(Edit.Tracks, SteppedTrack)

			local BounceTrack = AnimationData.CreateEmptyTrack("BounceHead")
			AnimationData.AddKeyframe(BounceTrack, 0, CFrame.identity, {
				Curve = "Easing",
				EasingStyle = "Bounce",
				EasingDirection = "Out",
				LeftHandle = nil,
				RightHandle = nil,
				HandleType = nil,
			})
			AnimationData.AddKeyframe(BounceTrack, 2, CFrame.Angles(0, math.rad(30), 0))
			table.insert(Edit.Tracks, BounceTrack)

			local Joints = {
				{ Name = "LinearArm", Part0Name = "HumanoidRootPart", Part1Name = "LinearArm" },
				{ Name = "SteppedLeg", Part0Name = "HumanoidRootPart", Part1Name = "SteppedLeg" },
				{ Name = "BounceHead", Part0Name = "HumanoidRootPart", Part1Name = "BounceHead" },
			}

			local KFS = Exporter.ExportAnimationBaked("KeyframeSequence", Edit, Joints)
			if not KFS then
				return
			end

			local Imported = Importer.Import("KeyframeSequence", KFS)
			if not Imported then
				KFS:Destroy()
				return
			end

			-- Verify curve modes survived the round-trip
			local TracksByName: { [string]: any } = {}
			for _, Track in Imported.Tracks do
				TracksByName[Track.Name] = Track
			end

			-- Linear track should have Linear curve
			if TracksByName["LinearArm"] then
				expect(TracksByName["LinearArm"].Channels.PositionX.Keyframes[1].Interpolation.Curve).toBe("Linear")
			end

			-- Stepped track should have Stepped curve
			if TracksByName["SteppedLeg"] then
				expect(TracksByName["SteppedLeg"].Channels.PositionX.Keyframes[1].Interpolation.Curve).toBe("Stepped")
			end

			-- Bounce track should have Easing/Bounce
			if TracksByName["BounceHead"] then
				local Interp = TracksByName["BounceHead"].Channels.PositionX.Keyframes[1].Interpolation
				expect(Interp.Curve).toBe("Easing")
				expect(Interp.EasingStyle).toBe("Bounce")
			end

			KFS:Destroy()
		end)
	end)
end)

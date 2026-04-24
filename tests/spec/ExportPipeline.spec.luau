--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.Luna.Packages.jest_globals)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect

local AnimationData = require(ReplicatedStorage.Luna.Core.AnimationData)
local ExportPipeline = require(ReplicatedStorage.Luna.Core.ExportPipeline)

describe("ExportPipeline", function()
	describe("BuildHierarchy", function()
		it("finds correct root (parent that is never a child)", function()
			local Joints = {
				{ Name = "Head", Part0Name = "Torso", Part1Name = "Head" },
				{ Name = "Arm", Part0Name = "Torso", Part1Name = "Arm" },
			}
			local Hierarchy = ExportPipeline.BuildHierarchy(Joints)
			expect(Hierarchy.Root).toBe("Torso")
		end)

		it("builds correct children", function()
			local Joints = {
				{ Name = "Head", Part0Name = "Torso", Part1Name = "Head" },
				{ Name = "Arm", Part0Name = "Torso", Part1Name = "Arm" },
				{ Name = "Hand", Part0Name = "Arm", Part1Name = "Hand" },
			}
			local Hierarchy = ExportPipeline.BuildHierarchy(Joints)

			-- Torso has 2 children: Head and Arm
			expect(#Hierarchy.Nodes["Torso"].Children).toBe(2)
			-- Arm has 1 child: Hand
			expect(#Hierarchy.Nodes["Arm"].Children).toBe(1)
			expect(Hierarchy.Nodes["Arm"].Children[1]).toBe("Hand")
		end)

		it("handles single joint", function()
			local Joints = {
				{ Name = "Head", Part0Name = "Root", Part1Name = "Head" },
			}
			local Hierarchy = ExportPipeline.BuildHierarchy(Joints)
			expect(Hierarchy.Root).toBe("Root")
			expect(#Hierarchy.Nodes["Root"].Children).toBe(1)
		end)
	end)

	describe("CollectKeyframeTimes", function()
		it("returns sorted unique times across all tracks", function()
			local Anim = AnimationData.CreateEmptyAnimation("Test", 2)

			local Track1 = AnimationData.CreateEmptyTrack("A")
			AnimationData.AddKeyframe(Track1, 0, CFrame.identity)
			AnimationData.AddKeyframe(Track1, 0.5, CFrame.identity)
			AnimationData.AddKeyframe(Track1, 1.0, CFrame.identity)
			table.insert(Anim.Tracks, Track1)

			local Track2 = AnimationData.CreateEmptyTrack("B")
			AnimationData.AddKeyframe(Track2, 0, CFrame.identity)
			AnimationData.AddKeyframe(Track2, 0.75, CFrame.identity)
			AnimationData.AddKeyframe(Track2, 1.0, CFrame.identity)
			table.insert(Anim.Tracks, Track2)

			local Times = ExportPipeline.CollectKeyframeTimes(Anim)
			expect(#Times).toBe(4) -- 0, 0.5, 0.75, 1.0
			expect(Times[1]).toBe(0)
			expect(Times[2]).toBe(0.5)
			expect(Times[3]).toBe(0.75)
			expect(Times[4]).toBe(1.0)
		end)

		it("returns empty array for animation with no tracks", function()
			local Anim = AnimationData.CreateEmptyAnimation("Empty", 1)
			local Times = ExportPipeline.CollectKeyframeTimes(Anim)
			expect(#Times).toBe(0)
		end)
	end)

	describe("CreateSnapshot", function()
		it("produces correct metadata", function()
			local Anim = AnimationData.CreateEmptyAnimation("Walk", 3)
			Anim.Looping = true
			Anim.Priority = 2

			local Track = AnimationData.CreateEmptyTrack("Leg")
			AnimationData.AddKeyframe(Track, 0, CFrame.identity)
			AnimationData.AddKeyframe(Track, 1, CFrame.new(5, 0, 0))
			table.insert(Anim.Tracks, Track)

			local Joints = {
				{ Name = "Leg", Part0Name = "Root", Part1Name = "Leg" },
			}

			local Snapshot = ExportPipeline.CreateSnapshot(Anim, Joints)
			expect(Snapshot.Metadata.Name).toBe("Walk")
			expect(Snapshot.Metadata.Duration).toBe(3)
			expect(Snapshot.Metadata.Looping).toBe(true)
			expect(Snapshot.Metadata.Priority).toBe(2)
		end)

		it("FrameCount equals number of unique keyframe times", function()
			local Anim = AnimationData.CreateEmptyAnimation("Test", 2)

			local Track = AnimationData.CreateEmptyTrack("Part")
			AnimationData.AddKeyframe(Track, 0, CFrame.identity)
			AnimationData.AddKeyframe(Track, 0.5, CFrame.identity)
			AnimationData.AddKeyframe(Track, 1, CFrame.identity)
			table.insert(Anim.Tracks, Track)

			local Joints = {
				{ Name = "Part", Part0Name = "Root", Part1Name = "Part" },
			}

			local Snapshot = ExportPipeline.CreateSnapshot(Anim, Joints)
			expect(Snapshot.FrameCount).toBe(3)
		end)

		it("frames contain correct track poses", function()
			local Anim = AnimationData.CreateEmptyAnimation("Test", 1)

			local Track = AnimationData.CreateEmptyTrack("Arm")
			AnimationData.AddKeyframe(Track, 0, CFrame.new(0, 0, 0))
			AnimationData.AddKeyframe(Track, 1, CFrame.new(10, 0, 0))
			table.insert(Anim.Tracks, Track)

			local Joints = {
				{ Name = "Arm", Part0Name = "Root", Part1Name = "Arm" },
			}

			local Snapshot = ExportPipeline.CreateSnapshot(Anim, Joints)

			-- First frame (t=0) should have Arm at origin
			expect(Snapshot.Frames[1].Time).toBe(0)
			expect(Snapshot.Frames[1].Poses["Arm"]).toBeDefined()
			expect(Snapshot.Frames[1].Poses["Arm"].Position.X).toBeCloseTo(0)

			-- Last frame (t=1) should have Arm at x=10
			expect(Snapshot.Frames[2].Time).toBe(1)
			expect(Snapshot.Frames[2].Poses["Arm"].Position.X).toBeCloseTo(10)
		end)
	end)

	describe("CreateBakedSnapshot", function()
		it("Linear segments produce only original keyframe times (no baking)", function()
			local Anim = AnimationData.CreateEmptyAnimation("Test", 1)

			local Track = AnimationData.CreateEmptyTrack("Arm")
			AnimationData.AddKeyframe(Track, 0, CFrame.new(0, 0, 0))
			AnimationData.AddKeyframe(Track, 1, CFrame.new(10, 0, 0))
			table.insert(Anim.Tracks, Track)

			local Joints = {
				{ Name = "Arm", Part0Name = "Root", Part1Name = "Arm" },
			}

			local Snapshot = ExportPipeline.CreateBakedSnapshot(Anim, Joints)
			-- Linear needs no baking — should have exactly 2 frames
			expect(Snapshot.FrameCount).toBe(2)
		end)

		it("Bezier segments produce baked intermediate frames", function()
			local Anim = AnimationData.CreateEmptyAnimation("Test", 1)
			Anim.FrameRate = 10 -- 10 FPS for easy counting

			local Track = AnimationData.CreateEmptyTrack("Arm")
			AnimationData.AddKeyframe(Track, 0, CFrame.new(0, 0, 0), {
				Curve = "Bezier",
				EasingStyle = nil,
				EasingDirection = nil,
				LeftHandle = nil,
				RightHandle = { TimeOffset = 0.3, ValueOffset = 0 },
				HandleType = "Free",
			})
			AnimationData.AddKeyframe(Track, 1, CFrame.new(10, 0, 0), {
				Curve = "Linear",
				EasingStyle = nil,
				EasingDirection = nil,
				LeftHandle = { TimeOffset = -0.3, ValueOffset = 0 },
				RightHandle = nil,
				HandleType = "Free",
			})
			table.insert(Anim.Tracks, Track)

			local Joints = {
				{ Name = "Arm", Part0Name = "Root", Part1Name = "Arm" },
			}

			local Snapshot = ExportPipeline.CreateBakedSnapshot(Anim, Joints)
			-- At 10 FPS over 1 second: 2 original + ~9 baked samples = more than 2
			expect(Snapshot.FrameCount > 2).toBe(true)
		end)

		it("Easing Quad segments are baked (no native Roblox equivalent)", function()
			local Anim = AnimationData.CreateEmptyAnimation("Test", 1)
			Anim.FrameRate = 10

			local Track = AnimationData.CreateEmptyTrack("Arm")
			AnimationData.AddKeyframe(Track, 0, CFrame.new(0, 0, 0), {
				Curve = "Easing",
				EasingStyle = "Quad",
				EasingDirection = "In",
				LeftHandle = nil,
				RightHandle = nil,
				HandleType = nil,
			})
			AnimationData.AddKeyframe(Track, 1, CFrame.new(10, 0, 0))
			table.insert(Anim.Tracks, Track)

			local Joints = {
				{ Name = "Arm", Part0Name = "Root", Part1Name = "Arm" },
			}

			local Snapshot = ExportPipeline.CreateBakedSnapshot(Anim, Joints)
			expect(Snapshot.FrameCount > 2).toBe(true)
		end)

		it("Easing Cubic segments are NOT baked (native Roblox equivalent)", function()
			local Anim = AnimationData.CreateEmptyAnimation("Test", 1)
			Anim.FrameRate = 10

			local Track = AnimationData.CreateEmptyTrack("Arm")
			AnimationData.AddKeyframe(Track, 0, CFrame.new(0, 0, 0), {
				Curve = "Easing",
				EasingStyle = "Cubic",
				EasingDirection = "InOut",
				LeftHandle = nil,
				RightHandle = nil,
				HandleType = nil,
			})
			AnimationData.AddKeyframe(Track, 1, CFrame.new(10, 0, 0))
			table.insert(Anim.Tracks, Track)

			local Joints = {
				{ Name = "Arm", Part0Name = "Root", Part1Name = "Arm" },
			}

			local Snapshot = ExportPipeline.CreateBakedSnapshot(Anim, Joints)
			-- Cubic is native — only 2 frames
			expect(Snapshot.FrameCount).toBe(2)
		end)

		it("native segments carry easing metadata", function()
			local Anim = AnimationData.CreateEmptyAnimation("Test", 1)

			local Track = AnimationData.CreateEmptyTrack("Arm")
			AnimationData.AddKeyframe(Track, 0, CFrame.new(0, 0, 0), {
				Curve = "Easing",
				EasingStyle = "Cubic",
				EasingDirection = "Out",
				LeftHandle = nil,
				RightHandle = nil,
				HandleType = nil,
			})
			AnimationData.AddKeyframe(Track, 1, CFrame.new(10, 0, 0))
			table.insert(Anim.Tracks, Track)

			local Joints = {
				{ Name = "Arm", Part0Name = "Root", Part1Name = "Arm" },
			}

			local Snapshot = ExportPipeline.CreateBakedSnapshot(Anim, Joints)
			local FirstFrame = Snapshot.Frames[1]
			expect(FirstFrame.Easing).never.toBeNil()
			if FirstFrame.Easing then
				expect(FirstFrame.Easing["Arm"]).never.toBeNil()
				if FirstFrame.Easing["Arm"] then
					expect(FirstFrame.Easing["Arm"].Style).toBe("Cubic")
					expect(FirstFrame.Easing["Arm"].Direction).toBe("Out")
				end
			end
		end)

		it("respects custom TargetFPS override", function()
			local Anim = AnimationData.CreateEmptyAnimation("Test", 1)
			Anim.FrameRate = 10

			local Track = AnimationData.CreateEmptyTrack("Arm")
			AnimationData.AddKeyframe(Track, 0, CFrame.new(0, 0, 0), {
				Curve = "Bezier",
				EasingStyle = nil,
				EasingDirection = nil,
				LeftHandle = nil,
				RightHandle = { TimeOffset = 0.3, ValueOffset = 0 },
				HandleType = "Free",
			})
			AnimationData.AddKeyframe(Track, 1, CFrame.new(10, 0, 0), {
				Curve = "Linear",
				EasingStyle = nil,
				EasingDirection = nil,
				LeftHandle = { TimeOffset = -0.3, ValueOffset = 0 },
				RightHandle = nil,
				HandleType = "Free",
			})
			table.insert(Anim.Tracks, Track)

			local Joints = {
				{ Name = "Arm", Part0Name = "Root", Part1Name = "Arm" },
			}

			local Snapshot10 = ExportPipeline.CreateBakedSnapshot(Anim, Joints, 10)
			local Snapshot30 = ExportPipeline.CreateBakedSnapshot(Anim, Joints, 30)
			-- Higher FPS = more frames
			expect(Snapshot30.FrameCount > Snapshot10.FrameCount).toBe(true)
		end)

		it("defaults FrameRate from animation", function()
			local Anim = AnimationData.CreateEmptyAnimation("Test", 1)
			expect(Anim.FrameRate).toBe(30) -- DEFAULT_FPS
		end)
	end)
end)

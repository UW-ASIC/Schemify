pub const types = @import("types.zig");
pub const gmid = @import("gmid.zig");
pub const gmic = @import("gmic.zig");
pub const spline = @import("spline.zig");
pub const sweep = @import("sweep.zig");
pub const nsga2 = @import("nsga2.zig");
pub const testbench = @import("testbench.zig");
pub const characterize = @import("characterize.zig");

// Re-export key types
pub const Problem = types.Problem;
pub const Mosfet = types.Mosfet;
pub const Bjt = types.Bjt;
pub const BjtKind = types.BjtKind;
pub const Resistor = types.Resistor;
pub const Parameter = types.Parameter;
pub const Specification = types.Specification;
pub const SpecKind = types.SpecKind;
pub const MosfetKind = types.MosfetKind;
pub const DeviceType = types.DeviceType;
pub const MatchGroup = types.MatchGroup;
pub const Individual = types.Individual;
pub const ParetoFront = types.ParetoFront;
pub const NsgaResult = types.NsgaResult;
pub const StopCondition = types.StopCondition;
pub const DeviceResult = types.DeviceResult;
pub const DiscoveredMeasurement = types.DiscoveredMeasurement;
pub const LinkedTestbench = types.LinkedTestbench;
pub const TbMeasurement = types.TbMeasurement;
pub const TbRunResult = types.TbRunResult;
pub const getLinkedTestbenches = types.getLinkedTestbenches;
pub const GmIdLookup = gmid.GmIdLookup;
pub const DeviceMetrics = gmid.DeviceMetrics;
pub const PhysicalMosfetParams = gmid.PhysicalMosfetParams;
pub const GmIcLookup = gmic.GmIcLookup;
pub const BjtMetrics = gmic.BjtMetrics;
pub const PhysicalBjtParams = gmic.PhysicalBjtParams;
pub const CubicSpline = spline.CubicSpline;
pub const SweepEngine = sweep.SweepEngine;
pub const SweepConfig = sweep.SweepConfig;
pub const SimCallback = sweep.SimCallback;
pub const Nsga2 = nsga2.Nsga2;
pub const Nsga2Config = nsga2.Config;
pub const EvalFn = nsga2.EvalFn;
pub const Nsga2StepResult = nsga2.StepResult;
pub const TestbenchRunner = testbench.TestbenchRunner;
pub const EnvEntry = testbench.EnvEntry;
pub const buildParamEnv = testbench.buildParamEnv;
pub const buildParamEnvFromDesign = testbench.buildParamEnvFromDesign;
pub const runLinkedTestbench = testbench.runLinkedTestbench;
pub const parseTbMeasurements = testbench.parseTbMeasurements;
pub const discoverMeasurements = testbench.discoverMeasurements;
pub const CharacterizationData = characterize.CharacterizationData;
pub const MosfetCharData = characterize.MosfetCharData;
pub const BjtCharData = characterize.BjtCharData;
pub const CharConfig = characterize.CharConfig;
pub const loadPdkData = characterize.loadPdkData;
pub const savePdkData = characterize.savePdkData;
pub const generateMosfetTestbench = characterize.generateMosfetTestbench;
pub const generateBjtTestbench = characterize.generateBjtTestbench;

comptime {
    _ = types;
    _ = gmid;
    _ = gmic;
    _ = spline;
    _ = sweep;
    _ = nsga2;
    _ = testbench;
    _ = characterize;
}

test {
    _ = types;
    _ = gmid;
    _ = gmic;
    _ = spline;
    _ = sweep;
    _ = nsga2;
    _ = testbench;
    _ = characterize;
}

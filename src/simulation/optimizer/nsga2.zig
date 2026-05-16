const std = @import("std");
const math = std.math;
const types = @import("types.zig");

const Individual = types.Individual;
const Problem = types.Problem;
const ParetoFront = types.ParetoFront;
const NsgaResult = types.NsgaResult;
const StopCondition = types.StopCondition;
const max_population = types.max_population;
const max_design_vars = types.max_design_vars;
const max_specs = types.max_specs;

// ── Evaluation function type ─────────────────────────────────────────────────

pub const EvalFn = *const fn (x: []const f64, problem: *const Problem, individual: *Individual) void;

// ── Step result ──────────────────────────────────────────────────────────────

pub const StepResult = struct {
    generation: u32 = 0,
    feasible_count: u32 = 0,
    best_feasible_idx: ?u32 = null,
    stop: ?StopCondition = null,
};

// ── Configuration ────────────────────────────────────────────────────────────

pub const Config = struct {
    pop_size: u32 = 0,
    max_generations: u32 = 100,
    eta_c: f64 = 20.0,
    eta_m: f64 = 20.0,
    crossover_prob: f64 = 0.9,
    mutation_prob: f64 = 0,
    seed: u64 = 42,
    stop_on_all_feasible: bool = false,
};

// ── PRNG (xoshiro256**) ──────────────────────────────────────────────────────

const Rng = struct {
    state: std.Random.Xoshiro256,

    fn init(seed: u64) Rng {
        return .{ .state = std.Random.Xoshiro256.init(seed) };
    }

    fn uniform01(self: *Rng) f64 {
        return @as(f64, @floatFromInt(self.state.next() >> 11)) / @as(f64, @floatFromInt(@as(u64, 1) << 53));
    }

    fn uniformRange(self: *Rng, lo: f64, hi: f64) f64 {
        return lo + self.uniform01() * (hi - lo);
    }

    fn randInt(self: *Rng, max: u32) u32 {
        return @intCast(self.state.next() % max);
    }

    fn shuffle(self: *Rng, arr: []u32) void {
        if (arr.len <= 1) return;
        var i: usize = arr.len - 1;
        while (i > 0) : (i -= 1) {
            const j = self.state.next() % (i + 1);
            const tmp = arr[i];
            arr[i] = arr[j];
            arr[j] = tmp;
        }
    }
};

// ── NSGA-II ──────────────────────────────────────────────────────────────────

pub const Nsga2 = struct {
    population: [max_population]Individual = undefined,
    offspring: [max_population]Individual = undefined,
    combined: [max_population * 2]Individual = undefined,

    pop_size: u32 = 0,
    n_vars: u32 = 0,
    n_objectives: u32 = 0,
    n_constraints: u32 = 0,

    lb: [max_design_vars]f64 = .{0.0} ** max_design_vars,
    ub: [max_design_vars]f64 = .{0.0} ** max_design_vars,

    generation: u32 = 0,
    rng: Rng = Rng.init(42),
    problem: *const Problem = undefined,
    cancelled: *std.atomic.Value(bool) = undefined,
    config: Config = .{},

    pub fn init(
        problem: *const Problem,
        config: Config,
        cancelled: *std.atomic.Value(bool),
    ) Nsga2 {
        var self = Nsga2{
            .problem = problem,
            .cancelled = cancelled,
            .config = config,
            .rng = Rng.init(config.seed),
        };

        self.n_vars = @intCast(problem.designVarCount());
        self.n_objectives = @intCast(problem.objectiveCount());
        self.n_constraints = @intCast(problem.constraintCount());

        _ = problem.getBounds(&self.lb, &self.ub);

        // Auto pop_size: max(50, 10 * n_vars), clamped to max_population
        if (config.pop_size == 0) {
            self.pop_size = @min(
                max_population,
                @max(50, 10 * self.n_vars),
            );
        } else {
            self.pop_size = @min(config.pop_size, max_population);
        }

        // Auto mutation_prob: 1/n_vars
        if (config.mutation_prob == 0 and self.n_vars > 0) {
            self.config.mutation_prob = 1.0 / @as(f64, @floatFromInt(self.n_vars));
        }

        return self;
    }

    // ── Seed population via Latin Hypercube Sampling ─────────────────────

    pub fn seedPopulation(self: *Nsga2) void {
        const nv: usize = self.n_vars;
        const ns: usize = self.pop_size;
        if (nv == 0 or ns == 0) return;

        // LHS: for each dimension, create a random permutation of strata
        // and place one sample per stratum with random jitter.
        for (0..nv) |d| {
            var perm: [max_population]u32 = undefined;
            for (0..ns) |i| perm[i] = @intCast(i);
            self.rng.shuffle(perm[0..ns]);

            const range = self.ub[d] - self.lb[d];
            const step_size = range / @as(f64, @floatFromInt(ns));

            for (0..ns) |i| {
                const stratum: f64 = @floatFromInt(perm[i]);
                const jitter = self.rng.uniform01();
                const val = self.lb[d] + (stratum + jitter) * step_size;
                self.population[i].x[d] = math.clamp(val, self.lb[d], self.ub[d]);
            }
        }

        // Initialize metadata on each individual.
        for (0..ns) |i| {
            self.population[i].n_vars = self.n_vars;
            self.population[i].n_objectives = self.n_objectives;
            self.population[i].n_constraints = self.n_constraints;
            self.population[i].valid = false; // not yet evaluated
            self.population[i].rank = 0;
            self.population[i].crowding_distance = 0;
            self.population[i].feasible = false;
        }
    }

    // ── One generation step ──────────────────────────────────────────────

    pub fn step(self: *Nsga2, eval_fn: EvalFn) StepResult {
        const ps: usize = self.pop_size;

        // 1. Evaluate unevaluated individuals in population.
        for (0..ps) |i| {
            if (!self.population[i].valid) {
                eval_fn(
                    self.population[i].x[0..self.n_vars],
                    self.problem,
                    &self.population[i],
                );
                self.population[i].feasible = self.population[i].isFeasible();
            }
        }

        // 2. Non-dominated sort + crowding distance on current population
        //    (needed for tournament selection).
        nonDominatedSort(self.population[0..ps], self.n_objectives);
        assignCrowdingByFront(self.population[0..ps], self.n_objectives);

        // 3. Create offspring via tournament selection + SBX + mutation.
        var child_idx: usize = 0;
        while (child_idx + 1 < ps) {
            const p1_idx = self.tournamentSelect(self.population[0..ps], self.pop_size);
            const p2_idx = self.tournamentSelect(self.population[0..ps], self.pop_size);

            self.sbxCrossover(
                &self.population[p1_idx],
                &self.population[p2_idx],
                &self.offspring[child_idx],
                &self.offspring[child_idx + 1],
            );

            self.polynomialMutation(&self.offspring[child_idx]);
            self.polynomialMutation(&self.offspring[child_idx + 1]);

            // Initialize child metadata.
            inline for (.{ child_idx, child_idx + 1 }) |ci| {
                self.offspring[ci].n_vars = self.n_vars;
                self.offspring[ci].n_objectives = self.n_objectives;
                self.offspring[ci].n_constraints = self.n_constraints;
                self.offspring[ci].valid = false;
                self.offspring[ci].rank = 0;
                self.offspring[ci].crowding_distance = 0;
                self.offspring[ci].feasible = false;
            }

            child_idx += 2;
        }
        // Handle odd pop_size: copy last parent as final child.
        if (child_idx < ps) {
            self.offspring[child_idx] = self.population[
                self.tournamentSelect(self.population[0..ps], self.pop_size)
            ];
            self.offspring[child_idx].valid = false;
            child_idx += 1;
        }

        // 4. Evaluate offspring.
        for (0..child_idx) |i| {
            eval_fn(
                self.offspring[i].x[0..self.n_vars],
                self.problem,
                &self.offspring[i],
            );
            self.offspring[i].feasible = self.offspring[i].isFeasible();
        }

        // 5. Combine parents + offspring.
        const combined_count: u32 = @intCast(ps + child_idx);
        @memcpy(self.combined[0..ps], self.population[0..ps]);
        @memcpy(self.combined[ps .. ps + child_idx], self.offspring[0..child_idx]);

        // 6. Non-dominated sort on combined population.
        nonDominatedSort(self.combined[0..combined_count], self.n_objectives);

        // 7. Crowding distance per front.
        assignCrowdingByFront(self.combined[0..combined_count], self.n_objectives);

        // 8. Select next generation: fill by rank, break ties by crowding distance.
        self.selectNextGeneration(combined_count);

        self.generation += 1;

        // Build step result.
        var result = StepResult{
            .generation = self.generation,
        };

        for (0..ps) |i| {
            if (self.population[i].feasible) {
                result.feasible_count += 1;
                if (result.best_feasible_idx == null) {
                    result.best_feasible_idx = @intCast(i);
                }
            }
        }

        // Check stop conditions.
        if (self.cancelled.load(.acquire)) {
            result.stop = .user_cancelled;
        } else if (self.generation >= self.config.max_generations) {
            result.stop = .max_generations;
        } else if (self.config.stop_on_all_feasible and result.feasible_count == self.pop_size) {
            result.stop = .all_specs_satisfied;
        }

        return result;
    }

    // ── Run loop ─────────────────────────────────────────────────────────

    pub fn run(self: *Nsga2, eval_fn: EvalFn) NsgaResult {
        self.seedPopulation();

        var last_result = StepResult{};
        while (true) {
            last_result = self.step(eval_fn);
            if (last_result.stop != null) break;
        }

        // Build NsgaResult.
        var result = NsgaResult{
            .generations = self.generation,
            .stop_reason = last_result.stop orelse .max_generations,
            .best_feasible_idx = last_result.best_feasible_idx,
        };

        // Copy rank-0 individuals into ParetoFront.
        var front_len: u32 = 0;
        const ps: usize = self.pop_size;
        for (0..ps) |i| {
            if (front_len >= max_population) break;
            if (self.population[i].rank == 0) {
                result.front.individuals[front_len] = self.population[i];
                front_len += 1;
            }
        }
        result.front.len = front_len;
        result.front.sortByRank();

        // Feasible ratio.
        var feasible_total: u32 = 0;
        for (0..ps) |i| {
            if (self.population[i].feasible) feasible_total += 1;
        }
        result.feasible_ratio = if (ps > 0)
            @as(f64, @floatFromInt(feasible_total)) / @as(f64, @floatFromInt(ps))
        else
            0;

        return result;
    }

    // ── Selection ────────────────────────────────────────────────────────

    fn selectNextGeneration(self: *Nsga2, combined_count: u32) void {
        const ps: usize = self.pop_size;
        const cc: usize = combined_count;

        // Sort combined by (rank asc, crowding_distance desc).
        std.mem.sort(Individual, self.combined[0..cc], {}, struct {
            fn lessThan(_: void, a: Individual, b: Individual) bool {
                if (a.rank != b.rank) return a.rank < b.rank;
                return a.crowding_distance > b.crowding_distance;
            }
        }.lessThan);

        // Take top pop_size individuals.
        @memcpy(self.population[0..ps], self.combined[0..ps]);
    }

    fn tournamentSelect(self: *Nsga2, pop: []const Individual, count: u32) usize {
        const a = self.rng.randInt(count);
        const b = self.rng.randInt(count);
        const ia = pop[a];
        const ib = pop[b];

        // Prefer lower rank; tie-break by higher crowding distance.
        if (ia.rank < ib.rank) return a;
        if (ib.rank < ia.rank) return b;
        if (ia.crowding_distance > ib.crowding_distance) return a;
        return b;
    }

    // ── SBX Crossover ────────────────────────────────────────────────────

    fn sbxCrossover(
        self: *Nsga2,
        p1: *const Individual,
        p2: *const Individual,
        c1: *Individual,
        c2: *Individual,
    ) void {
        const nv: usize = self.n_vars;
        const eta = self.config.eta_c;

        // Copy parents into children first.
        c1.* = p1.*;
        c2.* = p2.*;

        if (self.rng.uniform01() >= self.config.crossover_prob) return;

        for (0..nv) |i| {
            if (self.rng.uniform01() > 0.5) continue; // per-variable crossover

            const x1 = p1.x[i];
            const x2 = p2.x[i];
            if (@abs(x1 - x2) < 1e-14) continue;

            const lo = @min(x1, x2);
            const hi = @max(x1, x2);
            const diff = hi - lo;
            const lb_i = self.lb[i];
            const ub_i = self.ub[i];

            // Beta for lower child.
            const beta1 = 1.0 + 2.0 * (lo - lb_i) / diff;
            const alpha1 = 2.0 - math.pow(f64, beta1, -(eta + 1.0));
            const rand1 = self.rng.uniform01();
            const betaq1 = if (rand1 <= 1.0 / alpha1)
                math.pow(f64, rand1 * alpha1, 1.0 / (eta + 1.0))
            else
                math.pow(f64, 1.0 / (2.0 - rand1 * alpha1), 1.0 / (eta + 1.0));

            // Beta for upper child.
            const beta2 = 1.0 + 2.0 * (ub_i - hi) / diff;
            const alpha2 = 2.0 - math.pow(f64, beta2, -(eta + 1.0));
            const rand2 = self.rng.uniform01();
            const betaq2 = if (rand2 <= 1.0 / alpha2)
                math.pow(f64, rand2 * alpha2, 1.0 / (eta + 1.0))
            else
                math.pow(f64, 1.0 / (2.0 - rand2 * alpha2), 1.0 / (eta + 1.0));

            c1.x[i] = math.clamp(
                0.5 * ((x1 + x2) - betaq1 * diff),
                lb_i,
                ub_i,
            );
            c2.x[i] = math.clamp(
                0.5 * ((x1 + x2) + betaq2 * diff),
                lb_i,
                ub_i,
            );
        }
    }

    // ── Polynomial Mutation ──────────────────────────────────────────────

    fn polynomialMutation(self: *Nsga2, ind: *Individual) void {
        const nv: usize = self.n_vars;
        const eta = self.config.eta_m;
        const pm = self.config.mutation_prob;

        for (0..nv) |i| {
            if (self.rng.uniform01() >= pm) continue;

            const x = ind.x[i];
            const lb_i = self.lb[i];
            const ub_i = self.ub[i];
            const range = ub_i - lb_i;
            if (range < 1e-14) continue;

            const delta1 = (x - lb_i) / range;
            const delta2 = (ub_i - x) / range;
            const u = self.rng.uniform01();

            const deltaq = if (u < 0.5) blk: {
                const xy = 1.0 - delta1;
                const val = 2.0 * u + (1.0 - 2.0 * u) * math.pow(f64, xy, eta + 1.0);
                break :blk math.pow(f64, val, 1.0 / (eta + 1.0)) - 1.0;
            } else blk: {
                const xy = 1.0 - delta2;
                const val = 2.0 * (1.0 - u) + 2.0 * (u - 0.5) * math.pow(f64, xy, eta + 1.0);
                break :blk 1.0 - math.pow(f64, val, 1.0 / (eta + 1.0));
            };

            ind.x[i] = math.clamp(x + deltaq * range, lb_i, ub_i);
        }
    }
};

// ── Non-dominated sort (file-scoped) ─────────────────────────────────────────

// O(n^2 * m) where n = pop size, m = objectives. Adequate for n <= 400.
fn nonDominatedSort(pop: []Individual, n_objectives: u32) void {
    const n = pop.len;
    if (n == 0) return;

    // Domination bookkeeping — all inline.
    const max_combined = max_population * 2;
    var domination_count: [max_combined]u32 = .{0} ** max_combined;
    // Dominated sets: for each individual, which indices it dominates.
    // Using a flat [max_combined][max_combined] bool matrix would be huge (160KB).
    // Instead, use a compact list approach.
    var dominated_by: [max_combined]DominatedSet = undefined;
    for (0..n) |i| dominated_by[i] = .{};

    // Pairwise comparison.
    for (0..n) |i| {
        for (i + 1..n) |j| {
            const pi = &pop[i];
            const pj = &pop[j];

            // Constraint-domination: feasible always beats infeasible.
            // Between two infeasibles, the one with smaller total violation wins.
            const fi = pi.feasible;
            const fj = pj.feasible;

            if (fi and !fj) {
                dominated_by[i].add(@intCast(j));
                domination_count[j] += 1;
            } else if (!fi and fj) {
                dominated_by[j].add(@intCast(i));
                domination_count[i] += 1;
            } else if (!fi and !fj) {
                // Both infeasible: compare total constraint violation.
                const vi = totalViolation(pi);
                const vj = totalViolation(pj);
                if (vi < vj) {
                    dominated_by[i].add(@intCast(j));
                    domination_count[j] += 1;
                } else if (vj < vi) {
                    dominated_by[j].add(@intCast(i));
                    domination_count[i] += 1;
                }
            } else {
                // Both feasible: standard Pareto domination on objectives.
                if (dominatesObj(pi, pj, n_objectives)) {
                    dominated_by[i].add(@intCast(j));
                    domination_count[j] += 1;
                } else if (dominatesObj(pj, pi, n_objectives)) {
                    dominated_by[j].add(@intCast(i));
                    domination_count[i] += 1;
                }
            }
        }
    }

    // Assign ranks by front.
    var current_front: [max_combined]u16 = undefined;
    var front_size: u32 = 0;
    var rank: u16 = 0;

    // Front 0: all individuals with domination_count == 0.
    for (0..n) |i| {
        if (domination_count[i] == 0) {
            pop[i].rank = 0;
            current_front[front_size] = @intCast(i);
            front_size += 1;
        }
    }

    var next_front: [max_combined]u16 = undefined;
    while (front_size > 0) {
        var next_size: u32 = 0;
        rank += 1;

        for (0..front_size) |fi| {
            const idx = current_front[fi];
            const dom_set = &dominated_by[idx];
            for (dom_set.items[0..dom_set.len]) |dominated_idx| {
                domination_count[dominated_idx] -= 1;
                if (domination_count[dominated_idx] == 0) {
                    pop[dominated_idx].rank = rank;
                    next_front[next_size] = dominated_idx;
                    next_size += 1;
                }
            }
        }

        @memcpy(current_front[0..next_size], next_front[0..next_size]);
        front_size = next_size;
    }
}

/// Compact dominated set using inline array (max 400 entries).
const DominatedSet = struct {
    items: [max_population * 2]u16 = undefined,
    len: u16 = 0,

    fn add(self: *DominatedSet, idx: u16) void {
        if (self.len < max_population * 2) {
            self.items[self.len] = idx;
            self.len += 1;
        }
    }
};

fn dominatesObj(a: *const Individual, b: *const Individual, n_obj: u32) bool {
    var dominated_any = false;
    for (a.objectives[0..n_obj], b.objectives[0..n_obj]) |oa, ob| {
        if (oa > ob) return false;
        if (oa < ob) dominated_any = true;
    }
    return dominated_any;
}

fn totalViolation(ind: *const Individual) f64 {
    var total: f64 = 0;
    for (ind.constraints[0..ind.n_constraints]) |c| {
        if (c > 0) total += c;
    }
    return total;
}

// ── Crowding distance (file-scoped) ──────────────────────────────────────────

// O(n * m * log n) per front where n = front size, m = objectives.
fn crowdingDistance(front: []Individual, n_objectives: u32) void {
    const n = front.len;
    if (n <= 2) {
        for (front) |*ind| ind.crowding_distance = math.inf(f64);
        return;
    }

    // Reset distances.
    for (front) |*ind| ind.crowding_distance = 0;

    // Sort indices for each objective.
    for (0..n_objectives) |m| {
        // Build index array.
        var indices: [max_population * 2]u32 = undefined;
        for (0..n) |i| indices[i] = @intCast(i);

        // Sort indices by objective m.
        const ctx = SortCtx{ .front = front, .obj_idx = @intCast(m) };
        std.mem.sort(u32, indices[0..n], ctx, SortCtx.lessThan);

        // Objective range for normalization.
        const f_min = front[indices[0]].objectives[m];
        const f_max = front[indices[n - 1]].objectives[m];
        const range = f_max - f_min;

        // Boundary points get infinity.
        front[indices[0]].crowding_distance = math.inf(f64);
        front[indices[n - 1]].crowding_distance = math.inf(f64);

        if (range < 1e-14) continue;

        // Interior points.
        for (1..n - 1) |k| {
            const idx = indices[k];
            const prev_obj = front[indices[k - 1]].objectives[m];
            const next_obj = front[indices[k + 1]].objectives[m];
            front[idx].crowding_distance += (next_obj - prev_obj) / range;
        }
    }
}

const SortCtx = struct {
    front: []const Individual,
    obj_idx: u32,

    fn lessThan(ctx: SortCtx, a: u32, b: u32) bool {
        return ctx.front[a].objectives[ctx.obj_idx] < ctx.front[b].objectives[ctx.obj_idx];
    }
};

/// Assign crowding distance per-front rather than on the whole population.
fn assignCrowdingByFront(pop: []Individual, n_objectives: u32) void {
    const n = pop.len;
    if (n == 0) return;

    // Find max rank.
    var max_rank: u16 = 0;
    for (pop[0..n]) |ind| {
        if (ind.rank > max_rank) max_rank = ind.rank;
    }

    // For each rank, gather members and compute crowding distance.
    var rank: u16 = 0;
    while (rank <= max_rank) : (rank += 1) {
        var front_indices: [max_population * 2]u32 = undefined;
        var front_size: u32 = 0;

        for (0..n) |i| {
            if (pop[i].rank == rank) {
                front_indices[front_size] = @intCast(i);
                front_size += 1;
            }
        }

        if (front_size == 0) continue;

        // Build a temporary slice of pointers/indices and compute.
        // We compute crowding distance on a temporary array and write back.
        var front_buf: [max_population * 2]Individual = undefined;
        for (0..front_size) |fi| {
            front_buf[fi] = pop[front_indices[fi]];
        }

        crowdingDistance(front_buf[0..front_size], n_objectives);

        // Write back crowding distances.
        for (0..front_size) |fi| {
            pop[front_indices[fi]].crowding_distance = front_buf[fi].crowding_distance;
        }
    }
}

// ── Tests ────────────────────────────────────────────────────────────────────

test "nonDominatedSort: 3 individuals with clear dominance" {
    var pop: [3]Individual = undefined;

    // A dominates B and C; B dominates C; C is dominated by both.
    pop[0] = Individual{ .n_objectives = 2, .n_constraints = 0, .valid = true, .feasible = true };
    pop[0].objectives[0] = 1.0;
    pop[0].objectives[1] = 1.0;

    pop[1] = Individual{ .n_objectives = 2, .n_constraints = 0, .valid = true, .feasible = true };
    pop[1].objectives[0] = 2.0;
    pop[1].objectives[1] = 2.0;

    pop[2] = Individual{ .n_objectives = 2, .n_constraints = 0, .valid = true, .feasible = true };
    pop[2].objectives[0] = 3.0;
    pop[2].objectives[1] = 3.0;

    nonDominatedSort(&pop, 2);

    try std.testing.expectEqual(@as(u16, 0), pop[0].rank);
    try std.testing.expectEqual(@as(u16, 1), pop[1].rank);
    try std.testing.expectEqual(@as(u16, 2), pop[2].rank);
}

test "nonDominatedSort: non-dominated set" {
    var pop: [3]Individual = undefined;

    // All on the same front (no one dominates another).
    pop[0] = Individual{ .n_objectives = 2, .n_constraints = 0, .valid = true, .feasible = true };
    pop[0].objectives[0] = 1.0;
    pop[0].objectives[1] = 3.0;

    pop[1] = Individual{ .n_objectives = 2, .n_constraints = 0, .valid = true, .feasible = true };
    pop[1].objectives[0] = 2.0;
    pop[1].objectives[1] = 2.0;

    pop[2] = Individual{ .n_objectives = 2, .n_constraints = 0, .valid = true, .feasible = true };
    pop[2].objectives[0] = 3.0;
    pop[2].objectives[1] = 1.0;

    nonDominatedSort(&pop, 2);

    try std.testing.expectEqual(@as(u16, 0), pop[0].rank);
    try std.testing.expectEqual(@as(u16, 0), pop[1].rank);
    try std.testing.expectEqual(@as(u16, 0), pop[2].rank);
}

test "crowdingDistance: boundary points get infinity" {
    var front: [4]Individual = undefined;
    for (&front) |*ind| {
        ind.* = Individual{ .n_objectives = 2, .n_constraints = 0, .valid = true, .feasible = true };
    }

    front[0].objectives[0] = 1.0;
    front[0].objectives[1] = 4.0;
    front[1].objectives[0] = 2.0;
    front[1].objectives[1] = 3.0;
    front[2].objectives[0] = 3.0;
    front[2].objectives[1] = 2.0;
    front[3].objectives[0] = 4.0;
    front[3].objectives[1] = 1.0;

    crowdingDistance(&front, 2);

    // Boundary points (min/max on each objective) should be infinity.
    try std.testing.expect(math.isInf(front[0].crowding_distance));
    try std.testing.expect(math.isInf(front[3].crowding_distance));

    // Interior points should have finite positive distance.
    try std.testing.expect(front[1].crowding_distance > 0);
    try std.testing.expect(!math.isInf(front[1].crowding_distance));
    try std.testing.expect(front[2].crowding_distance > 0);
    try std.testing.expect(!math.isInf(front[2].crowding_distance));
}

test "SBX crossover: children within bounds" {
    var cancelled = std.atomic.Value(bool).init(false);

    var prob = Problem{};
    var p = types.Parameter{};
    p.setName("x0");
    p.min = 0.0;
    p.max = 1.0;
    p.enabled = true;
    prob.parameters.append(p);

    var p2 = types.Parameter{};
    p2.setName("x1");
    p2.min = 0.0;
    p2.max = 1.0;
    p2.enabled = true;
    prob.parameters.append(p2);

    var spec = types.Specification{ .kind = .minimize };
    spec.setName("obj0");
    prob.specs.append(spec);

    var nsga = Nsga2.init(&prob, .{ .pop_size = 10, .seed = 123 }, &cancelled);

    var parent1 = Individual{ .n_vars = 2, .n_objectives = 1, .n_constraints = 0, .valid = true };
    parent1.x[0] = 0.3;
    parent1.x[1] = 0.7;

    var parent2 = Individual{ .n_vars = 2, .n_objectives = 1, .n_constraints = 0, .valid = true };
    parent2.x[0] = 0.8;
    parent2.x[1] = 0.2;

    // Run crossover 100 times and verify children are in bounds.
    for (0..100) |_| {
        var c1: Individual = undefined;
        var c2: Individual = undefined;
        nsga.sbxCrossover(&parent1, &parent2, &c1, &c2);

        for (0..2) |d| {
            try std.testing.expect(c1.x[d] >= 0.0);
            try std.testing.expect(c1.x[d] <= 1.0);
            try std.testing.expect(c2.x[d] >= 0.0);
            try std.testing.expect(c2.x[d] <= 1.0);
        }
    }
}

test "polynomial mutation: values stay within bounds" {
    var cancelled = std.atomic.Value(bool).init(false);

    var prob = Problem{};
    var p = types.Parameter{};
    p.setName("x0");
    p.min = -5.0;
    p.max = 5.0;
    p.enabled = true;
    prob.parameters.append(p);

    var spec = types.Specification{ .kind = .minimize };
    spec.setName("obj0");
    prob.specs.append(spec);

    var nsga = Nsga2.init(&prob, .{
        .pop_size = 10,
        .seed = 7,
        .mutation_prob = 1.0, // always mutate for test coverage
    }, &cancelled);

    for (0..200) |_| {
        var ind = Individual{ .n_vars = 1, .n_objectives = 1, .n_constraints = 0, .valid = true };
        ind.x[0] = nsga.rng.uniformRange(-5.0, 5.0);
        nsga.polynomialMutation(&ind);
        try std.testing.expect(ind.x[0] >= -5.0);
        try std.testing.expect(ind.x[0] <= 5.0);
    }
}

test "NSGA-II: ZDT1-like 2-var 2-objective convergence" {
    // ZDT1 test problem:
    //   f1(x) = x[0]
    //   f2(x) = g * (1 - sqrt(x[0] / g))  where g = 1 + 9*x[1]/(n-1)
    //   x in [0, 1]^2
    //   Pareto front: x[1] = 0 => f2 = 1 - sqrt(f1)

    const Zdt1 = struct {
        fn eval(x: []const f64, _: *const Problem, ind: *Individual) void {
            const x0 = x[0];
            const x1 = x[1];
            const g = 1.0 + 9.0 * x1;
            ind.objectives[0] = x0;
            ind.objectives[1] = g * (1.0 - @sqrt(x0 / g));
            ind.n_objectives = 2;
            ind.n_constraints = 0;
            ind.valid = true;
            ind.feasible = true;
        }
    };

    var cancelled = std.atomic.Value(bool).init(false);

    var prob = Problem{};

    var p0 = types.Parameter{};
    p0.setName("x0");
    p0.min = 0.001; // avoid 0 exactly
    p0.max = 1.0;
    p0.enabled = true;
    prob.parameters.append(p0);

    var p1 = types.Parameter{};
    p1.setName("x1");
    p1.min = 0.0;
    p1.max = 1.0;
    p1.enabled = true;
    prob.parameters.append(p1);

    var s0 = types.Specification{ .kind = .minimize };
    s0.setName("f1");
    prob.specs.append(s0);

    var s1 = types.Specification{ .kind = .minimize };
    s1.setName("f2");
    prob.specs.append(s1);

    var nsga = Nsga2.init(&prob, .{
        .pop_size = 50,
        .max_generations = 30,
        .seed = 42,
    }, &cancelled);

    const result = nsga.run(&Zdt1.eval);

    try std.testing.expect(result.generations == 30);
    try std.testing.expect(result.front.len > 0);

    // All front members should be feasible.
    for (result.front.individuals[0..result.front.len]) |ind| {
        try std.testing.expect(ind.feasible);
        try std.testing.expect(ind.rank == 0);
    }

    // Pareto front members should have x[1] near 0 (optimal g ~ 1).
    // Check that at least some have low x[1].
    var low_x1_count: u32 = 0;
    for (result.front.individuals[0..result.front.len]) |ind| {
        if (ind.x[1] < 0.3) low_x1_count += 1;
    }
    try std.testing.expect(low_x1_count > 0);
}

test "NSGA-II: constrained problem finds feasible solutions" {
    // Minimize x[0] subject to x[0] >= 0.5
    const Constrained = struct {
        fn eval(x: []const f64, _: *const Problem, ind: *Individual) void {
            ind.objectives[0] = x[0];
            ind.constraints[0] = 0.5 - x[0]; // <= 0 when x[0] >= 0.5
            ind.n_objectives = 1;
            ind.n_constraints = 1;
            ind.valid = true;
            ind.feasible = ind.isFeasible();
        }
    };

    var cancelled = std.atomic.Value(bool).init(false);

    var prob = Problem{};
    var p0 = types.Parameter{};
    p0.setName("x0");
    p0.min = 0.0;
    p0.max = 1.0;
    p0.enabled = true;
    prob.parameters.append(p0);

    var s0 = types.Specification{ .kind = .minimize };
    s0.setName("f0");
    prob.specs.append(s0);

    var c0 = types.Specification{ .kind = .greater_equal, .target = 0.5 };
    c0.setName("c0");
    prob.specs.append(c0);

    var nsga = Nsga2.init(&prob, .{
        .pop_size = 30,
        .max_generations = 20,
        .seed = 99,
    }, &cancelled);

    const result = nsga.run(&Constrained.eval);
    try std.testing.expect(result.feasible_ratio > 0);

    // Best feasible should be near x = 0.5.
    if (result.front.len > 0) {
        const best = result.front.individuals[0];
        try std.testing.expect(best.x[0] >= 0.45);
        try std.testing.expect(best.x[0] <= 0.7);
    }
}

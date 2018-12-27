using PyPlot
using ReverseDiff
using LinearAlgebra: det

using Gen

# Example from Section 4 of Reversible jump Markov chain Monte Carlo
# computation and Bayesian model determination 

########################
# custom distributions #
########################

# minimum of k draws from uniform_continuous(lower, upper)

# we can sequentially sample the order statistics of a collection of K uniform
# continuous samples on the interval [a, b], by:
# x1 ~ min_uniform_continuous(a, b, K)
# x2 | x1 ~ min_uniform_continuous(x1, b, K-1)
# ..
# xK | x1 .. x_{K-1} ~ min_uniform_continuous(x_{K-1}, b, 1)

struct MinUniformContinuous <: Distribution{Float64} end
const min_uniform_continuous = MinUniformContinuous()

function Gen.logpdf(::MinUniformContinuous, x::Float64, lower::T, upper::U, k::Int) where {T<:Real,U<:Real}
    if x > lower && x < upper
        (k-1) * log(upper - x) + log(k) - k * log(upper - lower)
    else
        -Inf
    end
end

function Gen.random(::MinUniformContinuous, lower::T, upper::U, k::Int) where {T<:Real,U<:Real}
    # inverse CDF method
    p = rand()
    upper - (upper - lower) * (1. - p)^(1. / k)
end


# piecewise homogenous Poisson process 

# n intervals - n + 1 bounds
# (b_1, b_2]
# (b_2, b_3]
# ..
# (b_n, b_{n+1}]

function compute_total(bounds, rates)
    num_intervals = length(rates)
    if length(bounds) != num_intervals + 1
        error("Number of bounds does not match number of rates")
    end
    total = 0.
    bounds_ascending = true
    for i=1:num_intervals
        lower = bounds[i]
        upper = bounds[i+1]
        rate = rates[i]
        len = upper - lower
        if len <= 0
            bounds_ascending = false
        end
        total += len * rate
    end
    (total, bounds_ascending)
end

struct PiecewiseHomogenousPoissonProcess <: Distribution{Vector{Float64}} end
const piecewise_poisson_process = PiecewiseHomogenousPoissonProcess()

function Gen.logpdf(::PiecewiseHomogenousPoissonProcess, x::Vector{Float64}, bounds::Vector{Float64}, rates::Vector{Float64})
    cur = 1
    upper = bounds[cur+1]
    lpdf = 0.
    for xi in sort(x)
        if xi < bounds[1] || xi > bounds[end]
            error("x ($xi) lies outside of interval")
        end
        while xi > upper 
            cur += 1
            upper = bounds[cur+1]
        end
        lpdf += log(rates[cur])
    end
    (total, bounds_ascending) = compute_total(bounds, rates)
    if bounds_ascending
        lpdf - total
    else
        -Inf
    end
end

function Gen.random(::PiecewiseHomogenousPoissonProcess, bounds::Vector{Float64}, rates::Vector{Float64})
    x = Vector{Float64}()
    num_intervals = length(rates)
    for i=1:num_intervals
        lower = bounds[i]
        upper = bounds[i+1]
        rate = (upper - lower) * rates[i]
        n = random(poisson, rate)
        for j=1:n
            push!(x, random(uniform_continuous, lower, upper))
        end
    end
    x
end


#########
# model #
#########

@gen function model(T::Float64)

    # prior on number of change points
    k = @addr(poisson(3.), :k)

    # prior on the location of (sorted) change points
    change_pts = Vector{Float64}(undef, k)
    lower = 0.
    for i=1:k
        cp = @addr(min_uniform_continuous(lower, T, k-i+1), "cp$i")
        change_pts[i] = cp
        lower = cp
    end

    # k + 1 rate values
    # h$i is the rate for cp$(i-1) to cp$i where cp0 := 0 and where cp$(k+1) := T
    alpha = 1.
    beta = 200.
    rates = Float64[@addr(Gen.gamma(alpha, 1. / beta), "h$i") for i=1:k+1]

    # poisson process
    bounds = vcat([0.], change_pts, [T])
    @addr(piecewise_poisson_process(bounds, rates), "points")
end

function render(trace; ymax=0.02)
    T = get_args(trace)[1]
    assignment = get_assmt(trace)
    k = assignment[:k]
    bounds = vcat([0.], sort([assignment["cp$i"] for i=1:k]), [T])
    rates = [assignment["h$i"] for i=1:k+1]
    for i=1:length(rates)
        lower = bounds[i]
        upper = bounds[i+1]
        rate = rates[i]
        plot([lower, upper], [rate, rate], color="black", linewidth=2)
    end
    points = assignment["points"]
    scatter(points, -rand(length(points)) * (ymax/5.), color="black", s=5)
    ax = gca()
    xlim = [0., T]
    plot(xlim, [0., 0.], "--")
    ax[:set_xlim](xlim)
    ax[:set_ylim](-ymax/5., ymax)
end

function show_prior_samples()
    figure(figsize=(16,16))
    T = 40000.
    for i=1:16
        println("simulating $i")
        subplot(4, 4, i)
        (trace, ) = initialize(model, (T,), EmptyAssignment())
        render(trace; ymax=0.015)
    end
    tight_layout(pad=0)
    savefig("prior_samples.pdf")
end


###############
# height move #
###############

@gen function height_proposal(trace)
    assmt = get_assmt(trace)
    k = assmt[:k]
    i = @addr(uniform_discrete(1, k+1), :i)
    height = assmt["h$i"]
    @addr(uniform_continuous(height/2., height*2.), :height)
end

function height_involution(trace, fwd_assmt::Assignment, fwd_ret, proposal_args::Tuple)
    assmt = get_assmt(trace)
    model_args = get_args(trace)
    bwd_assmt = DynamicAssignment()
    constraints = DynamicAssignment()
    i = fwd_assmt[:i]
    bwd_assmt[:i] = i
    constraints["h$i"] = fwd_assmt[:height]
    bwd_assmt[:height] = assmt["h$i"]
    (new_trace, weight, _, _) = force_update(model_args, noargdiff, trace, constraints)
    (new_trace, bwd_assmt, weight)
end

height_move(trace) = general_mh(trace, height_proposal, (), height_involution)


#################
# position move #
#################

@gen function position_proposal(trace)
    assmt = get_assmt(trace)
    k = assmt[:k]
    i = @addr(uniform_discrete(1, k), :i)
    lower = (i == 1) ? 0. : assmt["cp$(i-1)"]
    upper = (i == k) ? T : assmt["cp$(i+1)"]
    @addr(uniform_continuous(lower, upper), :cp)
end

function position_involution(trace, fwd_assmt::Assignment, fwd_ret, proposal_args::Tuple)
    assmt = get_assmt(trace)
    model_args = get_args(trace)
    bwd_assmt = DynamicAssignment()
    constraints = DynamicAssignment()
    i = fwd_assmt[:i]
    bwd_assmt[:i] = i
    constraints["cp$i"] = fwd_assmt[:cp]
    bwd_assmt[:cp] = assmt["cp$i"]
    (new_trace, weight, _, _) = force_update(model_args, noargdiff, trace, constraints)
    (new_trace, bwd_assmt, weight)
end

position_move(trace) = general_mh(trace, position_proposal, (), position_involution)


######################
# birth / death move #
######################

@gen function birth_death_proposal(trace)
    T = get_args(trace)[1]
    assmt = get_assmt(trace)
    k = assmt[:k]
    if k == 0
        # birth only
        isbirth = true
    else
        # randomly choose birth or death
        isbirth = @addr(bernoulli(0.5), :isbirth)
    end
    if isbirth
        i = @addr(uniform_discrete(1, k+1), :i)
        lower = (i == 1) ? 0. : assmt["cp$(i-1)"]
        upper = (i == k+1) ? T : assmt["cp$i"]
        @addr(uniform_continuous(lower, upper), :cp_new)
        @addr(uniform_continuous(0., 1.), :u)
    else
        @addr(uniform_discrete(1, k), :i)
    end
end

function new_heights(arr)
    (cur_height, u, cur_cp, prev_cp, next_cp) = arr
    d_prev = cur_cp - prev_cp
    d_next = next_cp - cur_cp
    @assert d_prev > 0
    @assert d_next > 0
    d_total = d_prev + d_next
    log_cur_height = log(cur_height)
    log_ratio = log(1 - u) - log(u)
    prev_height = exp(log_cur_height - (d_next / d_total) * log_ratio)
    next_height = exp(log_cur_height + (d_prev / d_total) * log_ratio)
    @assert prev_height > 0.
    @assert next_height > 0.
    [prev_height, next_height]
end

function new_heights_inverse(arr)
    (prev_height, next_height, cur_cp, prev_cp, next_cp) = arr
    d_prev = cur_cp - prev_cp
    d_next = next_cp - cur_cp
    @assert d_prev > 0
    @assert d_next > 0
    d_total = d_prev + d_next
    log_prev_height = log(prev_height)
    log_next_height = log(next_height)
    cur_height = exp((d_prev / d_total) * log_prev_height + (d_next / d_total) * log_next_height)
    u = prev_height / (prev_height + next_height)
    @assert cur_height > 0.
    [cur_height, u]
end

# involution from (t, u) to (t', u')
function birth_death_involution(trace, fwd_assmt::Assignment, fwd_ret, proposal_args::Tuple)
    assmt = get_assmt(trace)
    model_args = get_args(trace)
    T = model_args[1]

    bwd_assmt = DynamicAssignment()

    # current number of changepoints
    k = assmt[:k]
    
    # if k == 0, then we can only do a birth move
    isbirth = (k == 0) || fwd_assmt[:isbirth]
    if k > 1 || isbirth
        bwd_assmt[:isbirth] = !isbirth
    end
    
    # the changepoint to be added or deleted
    i = fwd_assmt[:i]
    bwd_assmt[:i] = i

    # populate constraints
    constraints = DynamicAssignment()
    if isbirth
        constraints[:k] = k + 1

        cp_new = fwd_assmt[:cp_new]
        cp_prev = (i == 1) ? 0. : assmt["cp$(i-1)"]
        cp_next = (i == k+1) ? T : assmt["cp$i"]

        # set new changepoint
        constraints["cp$i"] = cp_new

        # shift up changepoints
        for j=i+1:k+1
            constraints["cp$j"] = assmt["cp$(j-1)"]
        end

        # compute new heights
        h_cur = assmt["h$i"]
        u = fwd_assmt[:u]
        (h_prev, h_next) = new_heights([h_cur, u, cp_new, cp_prev, cp_next])
        J = ReverseDiff.jacobian(new_heights, [h_cur, u, cp_new, cp_prev, cp_next])[:,1:2]

        # set new heights
        constraints["h$i"] = h_prev
        constraints["h$(i+1)"] = h_next

        # shift up heights
        for j=i+2:k+2
            constraints["h$j"] = assmt["h$(j-1)"]
        end
    else
        constraints[:k] = k - 1

        cp_new = assmt["cp$i"]
        cp_prev = (i == 1) ? 0. : assmt["cp$(i-1)"]
        cp_next = (i == k) ? T : assmt["cp$(i+1)"]
        bwd_assmt[:cp_new] = cp_new

        # shift down changepoints
        for j=i:k-1
            constraints["cp$j"] = assmt["cp$(j+1)"]
        end

        # compute cur height and u
        h_prev = assmt["h$i"]
        h_next = assmt["h$(i+1)"]
        (h_cur, u) = new_heights_inverse([h_prev, h_next, cp_new, cp_prev, cp_next])
        J = ReverseDiff.jacobian(new_heights_inverse, [h_prev, h_next, cp_new, cp_prev, cp_next])[:,1:2]
        bwd_assmt[:u] = u

        # set cur height
        constraints["h$i"] = h_cur

        # shift down heights
        for j=i+1:k
            constraints["h$j"] = assmt["h$(j+1)"]
        end
    end

    (new_trace, weight, _, _) = force_update(model_args, noargdiff, trace, constraints)
    (new_trace, bwd_assmt, weight + log(abs(det(J))))
end

birth_death_move(trace) = general_mh(trace, birth_death_proposal, (), birth_death_involution)

function mcmc_step(trace)
    k = get_assmt(trace)[:k]
    (trace, _) = height_move(trace)
    if k > 0
        (trace, _) = position_move(trace)
    end
    (trace, _) = birth_death_move(trace)
    trace
end

function simple_mcmc_step(trace)
    k = get_assmt(trace)[:k]
    (trace, _) = height_move(trace)
    if k > 0
        (trace, _) = position_move(trace)
    end
    (trace, _) = default_mh(trace, k_selection)
    trace
end

function do_mcmc(T, num_steps::Int)
    (trace, _) = initialize(model, (T,), observations)
    for iter=1:num_steps
        k = get_assmt(trace)[:k]
        if iter % 1000 == 0
            println("iter $iter of $num_steps, k: $k")
        end
        trace = mcmc_step(trace)
    end
    trace
end

const k_selection = select(:k)

function do_simple_mcmc(T, num_steps::Int)
    (trace, _) = initialize(model, (T,), observations)
    for iter=1:num_steps
        k = get_assmt(trace)[:k]
        if iter % 1000 == 0
            println("iter $iter of $num_steps, k: $k")
        end
        trace = simple_mcmc_step(trace)
    end
    trace
end


########################
# inference experiment #
########################

import Random
Random.seed!(1)

# load data set
import CSV
function load_data_set()
    df = CSV.read("$(@__DIR__)/coal.csv")
    dates = df[1]
    dates = dates .- minimum(dates)
    dates * 365.25 # convert years to days
end

const points = load_data_set()
const T = maximum(points)
const observations = DynamicAssignment()
observations["points"] = points

function show_posterior_samples()
    figure(figsize=(16,16))
    for i=1:16
        println("replicate $i")
        subplot(4, 4, i)
        trace = do_mcmc(T, 200)
        render(trace; ymax=0.015)
    end
    tight_layout(pad=0)
    savefig("posterior_samples.pdf")

    figure(figsize=(16,16))
    for i=1:16
        println("replicate $i")
        subplot(4, 4, i)
        trace = do_simple_mcmc(T, 200)
        render(trace; ymax=0.015)
    end
    tight_layout(pad=0)
    savefig("posterior_samples_simple.pdf")
end

function get_rate_vector(trace, test_points)
    assignment = get_assmt(trace)
    k = assignment[:k]
    cps = [assignment["cp$i"] for i=1:k]
    hs = [assignment["h$i"] for i=1:k+1]
    rate = Vector{Float64}()
    cur_h_idx = 1
    cur_h = hs[cur_h_idx]
    next_cp_idx = 1
    upper = (next_cp_idx == k + 1) ? T : cps[next_cp_idx]
    for x in test_points
        while x > upper
            next_cp_idx += 1
            upper = (next_cp_idx == k + 1) ? T : cps[next_cp_idx]
            cur_h_idx += 1
            cur_h = hs[cur_h_idx]
        end
        push!(rate, cur_h)
    end
    rate
end

# compute posterior mean rate curve

function plot_posterior_mean_rate()
    test_points = collect(1.0:10.0:T)
    rates = Vector{Vector{Float64}}()
    num_samples = 0
    num_steps = 20000
    for reps=1:20
        (trace, _) = initialize(model, (T,), observations)
        for iter=1:num_steps
            if iter % 1000 == 0
                println("iter $iter of $num_steps, k: $(get_assmt(trace)[:k])")
            end
            trace = mcmc_step(trace)
            if iter > 5000
                num_samples += 1
                rate_vector = get_rate_vector(trace, test_points)
                @assert length(rate_vector) == length(test_points)
                push!(rates, rate_vector)
            end
        end
    end
    posterior_mean_rate = zeros(length(test_points))
    for rate in rates
        posterior_mean_rate += rate / Float64(num_samples)
    end
    ymax = 0.010
    figure()
    plot(test_points, posterior_mean_rate, color="black")
    scatter(points, -rand(length(points)) * (ymax/6.), color="black", s=5)
    ax = gca()
    xlim = [0., T]
    plot(xlim, [0., 0.], "--")
    ax[:set_xlim](xlim)
    ax[:set_ylim](-ymax/5., ymax)
    savefig("posterior_mean_rate.pdf")
end

function plot_trace_plot()
    figure(figsize=(8, 4))

    # reversible jump
    (trace, _) = initialize(model, (T,), observations)
    height1 = Float64[]
    num_clusters_vec = Int[]
    burn_in = 0
    for iter=1:burn_in + 1000 
        trace = mcmc_step(trace)
        if iter > burn_in
            push!(num_clusters_vec, get_assmt(trace)[:k])
        end
    end
    subplot(2, 1, 1)
    plot(num_clusters_vec, "b")

    # simple MCMC
    (trace, _) = initialize(model, (T,), observations)
    height1 = Float64[]
    num_clusters_vec = Int[]
    burn_in = 0
    for iter=1:burn_in + 1000 
        trace = simple_mcmc_step(trace)
        if iter > burn_in
            push!(num_clusters_vec, get_assmt(trace)[:k])
        end
    end
    subplot(2, 1, 2)
    plot(num_clusters_vec, "b")

    savefig("trace_plot.pdf")
end

println("showing prior samples...")
show_prior_samples()

println("showing posterior samples...")
show_posterior_samples()

println("estimating posterior mean rate...")
plot_posterior_mean_rate()

println("making trace plot...")
plot_trace_plot()

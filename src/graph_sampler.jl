"""
    ABCDParams

A structure holding parameters for ABCD graph generator. Fields:
* w::Vector{Int}: a sorted in descending order list of vertex degrees
* s::Vector{Int}: a sorted in descending order list of cluster sizes
* μ::Float64:     mixing parameter
* isCL::Bool:     if `true` a Chung-Lu model is used, otherwise configuration model
* islocal::Bool:  if `true` mixing parameter restriction is cluster local, otherwise
                  it is only global
"""
struct ABCDParams
    w::Vector{Int}
    s::Vector{Int}
    μ::Float64
    isCL::Bool
    islocal::Bool

    function ABCDParams(w, s, μ, isCL, islocal)
        length(w) == sum(s) || throw(ArgumentError("inconsistent data"))
        0 ≤ μ ≤ 1 || throw(ArgumentError("inconsistent data"))

        new(sort(w, rev=true),
            sort(s, rev=true),
            μ, isCL, islocal)
    end
end

function randround(x)
    d = floor(Int, x)
    d + (rand() < x - d)
end

function populate_clusters(params::ABCDParams)
    nμ = 1 - params.μ
    w, s = params.w, params.s
    @assert length(w) == sum(s)
    @assert 0 ≤ nμ ≤ 1
    @assert issorted(w, rev=true)
    @assert issorted(s, rev=true)

    slots = copy(s)
    clusters = Int[]
    j = 0
    for (i, vw) in enumerate(w)
        while j + 1 ≤ length(s) && nμ * vw + 1 ≤ s[j + 1]
            j += 1
        end
        j == 0 && throw(ArgumentError("could not find a large enough cluster for vertex of weight $vw"))
        wts = Weights(view(slots, 1:j))
        wts.sum == 0 && throw(ArgumentError("could not find an empty slot for vertex of weight $vw"))
        loc = sample(1:j, wts)
        push!(clusters, loc)
        slots[loc] -= 1
    end
    clusters
end

function CL_model(clusters, params)
    @assert params.isCL
    w, s, μ = params.w, params.s, params.μ
    cluster_weight = zeros(Int, length(s))
    for i in axes(w, 1)
        cluster_weight[clusters[i]] += w[i]
    end
    total_weight = sum(cluster_weight)
    if params.islocal
        ξl = @. μ / (1.0 - cluster_weight / total_weight)
        maximum(ξl) >= 1 && throw(ArgumentError("μ is too large to generate a graph"))
    else
        ξg = μ / (1.0 - sum(x -> x^2, cluster_weight) / total_weight^2)
        ξg >= 1 && throw(ArgumentError("μ is too large to generate a graph"))
    end

    wf = float.(w)
    edges = Set{Tuple{Int, Int}}()
    for i in axes(s, 1)
        local_edges = Set{Tuple{Int, Int}}()
        idxᵢ = findall(==(i), clusters)
        wᵢ = wf[idxᵢ]
        ξ = params.islocal ? ξl[i] : ξg
        m = randround((1-ξ) * sum(wᵢ) / 2)
        ww = Weights(wᵢ)
        while length(local_edges) < m
            a = sample(idxᵢ, ww, m - length(local_edges))
            b = sample(idxᵢ, ww, m - length(local_edges))
            for (p, q) in zip(a, b)
                p != q && push!(local_edges, minmax(p, q))
            end
        end
        union!(edges, local_edges)
    end
    wwt = if params.islocal
        Weights([ξl[clusters[i]]*x for (i,x) in enumerate(wf)])
    else
        Weights(ξg * wf)
    end
    while 2*length(edges) < total_weight
        a = sample(axes(w, 1), wwt, randround(total_weight / 2) - length(edges))
        b = sample(axes(w, 1), wwt, randround(total_weight / 2) - length(edges))
        for (p, q) in zip(a, b)
            p != q && push!(edges, minmax(p, q))
        end
    end
    edges
end

function config_model(clusters, params)
    @assert !params.isCL
    w, s, μ = params.w, params.s, params.μ

    cluster_weight = zeros(Int, length(s))
    for i in axes(w, 1)
        cluster_weight[clusters[i]] += w[i]
    end
    total_weight = sum(cluster_weight)
    if params.islocal
        ξl = @. μ / (1.0 - cluster_weight / total_weight)
        maximum(ξl) >= 1 && throw(ArgumentError("μ is too large to generate a graph"))
        w_internal_raw = [w[i] * (1 - ξl[clusters[i]]) for i in axes(w, 1)]
    else
        ξg = μ / (1.0 - sum(x -> x^2, cluster_weight) / total_weight^2)
        ξg >= 1 && throw(ArgumentError("μ is too large to generate a graph"))
        w_internal_raw = [w[i] * (1 - ξg) for i in axes(w, 1)]
    end

    clusterlist = [Int[] for i in axes(s, 1)]
    for i in axes(clusters, 1)
        push!(clusterlist[clusters[i]], i)
    end

    edges = Set{Tuple{Int, Int}}()

    unresolved_collisions = 0
    w_internal = zeros(Int, length(w_internal_raw))
    for cluster in clusterlist
        maxw_idx = argmax(view(w_internal_raw, cluster))
        wsum = 0
        for i in axes(cluster, 1)
            if i != maxw_idx
                neww = randround(w_internal_raw[cluster[i]])
                w_internal[cluster[i]] = neww
                wsum += neww
            end
        end
        maxw = floor(Int, w_internal_raw[cluster[maxw_idx]])
        w_internal[cluster[maxw_idx]] = maxw + (isodd(wsum) ? iseven(maxw) : isodd(maxw))

        stubs = Int[]
        for i in cluster
            for j in 1:w_internal[i]
                push!(stubs, i)
            end
        end
        @assert sum(w_internal[cluster]) == length(stubs)
        shuffle!(@view stubs[1+w_internal[cluster[1]]:end])
        local_edges = Set{Tuple{Int, Int}}()
        recycle = Tuple{Int,Int}[]
        for i in 1:length(stubs)÷2
            e = minmax(stubs[i], stubs[end+1-i])
            if (e[1] == e[2]) || (e in local_edges)
                push!(recycle, e)
            else
                push!(local_edges, e)
            end
        end
        last_recycle = length(recycle)
        recycle_counter = last_recycle
        while !isempty(recycle)
            recycle_counter -= 1
            if recycle_counter < 0
                if length(recycle) < last_recycle
                    last_recycle = length(recycle)
                    recycle_counter = last_recycle
                else
                    break
                end
            end
            p1 = popfirst!(recycle)
            from_recycle = 2 * length(recycle) / length(stubs)
            success = false
            for _ in 1:2:length(stubs)
                p2 = if rand() < from_recycle
                    used_recycle = true
                    recycle_idx = rand(axes(recycle, 1))
                    recycle[recycle_idx]
                else
                    used_recycle = false
                    rand(local_edges)
                end
                if rand() < 0.5
                    newp1 = minmax(p1[1], p2[1])
                    newp2 = minmax(p1[2], p2[2])
                else
                    newp1 = minmax(p1[1], p2[2])
                    newp2 = minmax(p1[2], p2[1])
                end
                if newp1 == newp2
                    good_choice = false
                elseif (newp1[1] == newp1[2]) || (newp1 in local_edges)
                    good_choice = false
                elseif (newp2[1] == newp2[2]) || (newp2 in local_edges)
                    good_choice = false
                else
                    good_choice = true
                end
                if good_choice
                    if used_recycle
                        recycle[recycle_idx], recycle[end] = recycle[end], recycle[recycle_idx]
                        pop!(recycle)
                    else
                        pop!(local_edges, p2)
                    end
                    success = true
                    push!(local_edges, newp1)
                    push!(local_edges, newp2)
                    break
                end
            end
            success || push!(recycle, p1)
        end
        old_len = length(edges)
        union!(edges, local_edges)
        @assert length(edges) == old_len + length(local_edges)
        @assert 2 * (length(local_edges) + length(recycle)) == length(stubs)
        for (a, b) in recycle
            w_internal[a] -= 1
            w_internal[b] -= 1
        end
        unresolved_collisions += length(recycle)
    end

    if VERBOSE[]
        println("Unresolved_collisions: ", unresolved_collisions,
                "; fraction: ", 2 * unresolved_collisions / total_weight)
    end

    stubs = Int[]
    for i in axes(w, 1)
        for j in w_internal[i]+1:w[i]
            push!(stubs, i)
        end
    end
    @assert sum(w) == length(stubs) + sum(w_internal)
    shuffle!(stubs)
    global_edges = Set{Tuple{Int, Int}}()
    recycle = Tuple{Int,Int}[]
    for i in 1:length(stubs) ÷ 2
        e = minmax(stubs[i], stubs[end+1-i])
        if (e[1] == e[2]) || (e in global_edges) || (e in edges)
            push!(recycle, e)
        else
            push!(global_edges, e)
        end
    end
    while !isempty(recycle)
        p1 = pop!(recycle)
        from_recycle = 2 * length(recycle) / length(stubs)
        p2 = if rand() < from_recycle
            i = rand(axes(recycle, 1))
            recycle[i], recycle[end] = recycle[end], recycle[i]
            pop!(recycle)
        else
            x = rand(global_edges)
            pop!(global_edges, x)
        end
        if rand() < 0.5
            newp1 = minmax(p1[1], p2[1])
            newp2 = minmax(p1[2], p2[2])
        else
            newp1 = minmax(p1[1], p2[2])
            newp2 = minmax(p1[2], p2[1])
        end
        for newp in (newp1, newp2)
            if (newp[1] == newp[2]) || (newp in global_edges) || (newp in edges)
                push!(recycle, newp)
            else
                push!(global_edges, newp)
            end
        end
    end
    old_len = length(edges)
    union!(edges, global_edges)
    @assert length(edges) == old_len + length(global_edges)
    @assert 2 * length(global_edges) == length(stubs)
    edges
end

"""
    gen_graph(params::ABCDParams)

Generate ABCD graph following parameters specified in `params`.

Return a named tuple containing a set of edges of the graph and a list of cluster
assignments of the vertices.
The ordering of vertices and clusters is in descending order (as in `params`).
"""
function gen_graph(params::ABCDParams)
    clusters = populate_clusters(params)
    edges = params.isCL ? CL_model(clusters, params) : config_model(clusters, params)
    (edges=edges, clusters=clusters)
end

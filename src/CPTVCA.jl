module CPTVCA

using Arpack
using ExactDiagonalization
using ExactDiagonalization: matrix
using KrylovKit
using LinearAlgebra
using QuantumLattices
using Serialization

export GreenFunction, InitialState, FInitialState, SInitialState, Kryvals, LehmannGreenFunction, Sysvals, Perioder, VCA, GFSolver, EDSolver, QMCSolver
export initialstate, clusterGreenFunction, differQuadraticTerms, VCAGreenFunction, singleparticlespectrum, statedensity, saveData, loadData

"""
    abstract type GreenFunction
"""
abstract type GreenFunction end

"""
    abstract type InitialState

The Operators needed in calculating the initial vector in Lanczos iteration method of krylov subspace
"""
abstract type InitialState end

"""
    FInitialState{O<:Operator} <: InitialState
    SInitialState{O<:Operator} <: InitialState

The Operators in a fermion/spin system needed in calculating the initial vector in Lanczos iteration method of krylov subspace 
"""
struct FInitialState{O<:Operator} <: InitialState
    sign::Int
    ops::OperatorSum{O}
    function FInitialState(sign::Int, key::Tuple)
        ops = Operators(1*CompositeIndex(Index(key[2], FID{:f}(key[3], key[1], sign)), [0.0, 0.0], [0.0, 0.0]))
        new{eltype(ops)}(sign, ops)
    end
end
struct SInitialState <: InitialState
    sign::Int
    key::Tuple
    function SInitialState(sign::Int, key::Tuple)
        #to be update
    end
end

"""
    initialstate(::EDKind{:FED}, sign::Int, key::Tuple) -> FInitialState
    initialstate(::EDKind{:SED}, sign::Int, key::Tuple) -> SInitialState

Get the Operators needed in calculating the initial vector
"""
function initialstate(::EDKind{:FED}, sign::Int, key::Tuple) FInitialState(sign, key) end
function initialstate(::EDKind{:SED}, sign::Int, key::Tuple) SInitialState(sign, key) end

"""
    genkrylov(matrix::AbstractMatrix, sstate::AbstractVector, m::Int)

Generate a krylov subspace with Lanczos iteration method
"""
function genkrylov(matrix::AbstractMatrix, sstate::AbstractVector, m::Int)
    matrix = Hermitian(matrix)
    orth = KrylovKit.ModifiedGramSchmidt()
    iterator = LanczosIterator(matrix, sstate, orth)
    factorization = KrylovKit.initialize(iterator)
    for _ in 1:m-1
        KrylovKit.expand!(iterator, factorization)
    end
    basis_vectors = basis(factorization)
    T = rayleighquotient(factorization)
    return basis_vectors, T
end

"""
    Kryvals

The information obtained with the krylov subspace method that needed in calculating the cluster Green function
"""
struct Kryvals
    tridims::AbstractVector
    norms::AbstractVector
    projects::AbstractMatrix
    function Kryvals(matrix::AbstractMatrix, initialstates::AbstractVector, m::Int=200)
        n = length(initialstates)
        tridims, norms, projects = Vector{Matrix}(undef,n), Vector{Real}(undef,n), Matrix{Vector}(undef,n,n)
        for i in 1:n
            krybasis, tridims[i] = genkrylov(matrix, initialstates[i], m)
            norms[i] = √(initialstates[i]' * initialstates[i])
            for j in 1:n
                projects[i, j] = KrylovKit.project!(zeros(Real, m), krybasis, initialstates[j])
            end
        end
        new(tridims, norms, projects)
    end
end

"""
    Sysvals{K<:EDKind}

The all information needed to calculate the Green Function of a finite size system 
"""
struct Sysvals{K<:EDKind}
    gsenergy::Real
    kryvals₁::Kryvals
    kryvals₂::Kryvals
end
function Sysvals(k::EDKind, eigensystem::Eigen, ops::OperatorSum, target::TargetSpace, table::Table; m::Int=200)
    gse, gs = eigensystem.values[1], eigensystem.vectors[:,1]
    sets₁, sets₂ = Vector{Vector}(), Vector{Vector}()
    H₁, H₂ = matrix(ops, (target[2], target[2]), table), matrix(ops, (target[3], target[3]), table)
    orderkeys = sort(collect(keys(table)), by = x -> table[x])
    for key in orderkeys
        ops₁, ops₂ = initialstate(k, 1, key).ops, initialstate(k, 2, key).ops
        initialstate₁, initialstate₂ = (matrix(ops₁, (target[2], target[1]), table)*gs)[:,1], (matrix(ops₂, (target[3], target[1]), table)*gs)[:,1]
        push!(sets₁, initialstate₁)
        push!(sets₂, initialstate₂)
    end
    kryvals₁, kryvals₂ = Kryvals(H₁, sets₁, m), Kryvals(H₂, sets₂, m)
    return Sysvals{typeof(k)}(gse, kryvals₁, kryvals₂)
end

"""
    LehmannGreenFunction{R<:Real, I<:Int, S<:Kryvals} <: GreenFunction

The minimum element of a Green function in Lehmann representation, e.g. <<c_{im↑}|c†_{jn↓}>>. for sign, +1 repersent advanced Green function, -1 repersent retarded Green function
"""
struct LehmannGreenFunction <: GreenFunction
    sign::Int 
    gsenergy::Real
    tridim::AbstractMatrix
    norm::Real
    project::AbstractVector
    function LehmannGreenFunction(sign::Int, kryvals::Kryvals, gsenergy::Real, l::Int, r::Int)
        tridim, norm, project = kryvals.tridims[r], kryvals.norms[r], kryvals.projects[r, l]
        new(sign, gsenergy, tridim, norm, project)
    end
end
function (gf::LehmannGreenFunction)(ω::Real, μ::Real, η::Real)
    Im = Matrix{Complex}(I, size(gf.tridim, 1), size(gf.tridim, 2))
    lgf = dot(gf.project, inv((ω + η*im + μ - gf.sign*gf.gsenergy)*Im + gf.sign*Matrix(gf.tridim))[:, 1])*gf.norm
    return lgf
end

"""
    The solver to calculate the cluster Green function
"""
abstract type GFSolver end

"""
    The ED solver to calculate the cluster Green function
"""
struct EDSolver <: GFSolver 
    sysvals::Sysvals
    function EDSolver(k::EDKind, refergenerator::OperatorGenerator, target::TargetSpace, table::Table; m::Int=200)
        rops = expand(refergenerator)
        Hₘ = matrix(rops, (target[1], target[1]), table)
        eigens = eigs(Hₘ; nev=1, which=:SR, tol=0.0,maxiter=300,  sigma=nothing, ritzvec=true, v0=[])
        eigensystem = Eigen(eigens[1], eigens[2])
        sysvals = Sysvals(k, eigensystem, rops, target, table; m=m)
        new(sysvals)
    end
end

"""
    The QMC solver to calculate the cluster Green function
"""
struct QMCSolver <: GFSolver end


"""
    clusterGreenFunction(solver::GFSolver, ω::Real, μ::Real; η=0.05) -> Matrix

Calculate the cluster Green function with ED solver
"""
function clusterGreenFunction(solver::GFSolver, ω::Real, μ::Real, η::Real)
    sys = solver.sysvals
    gfm = zeros(Complex, length(sys.kryvals₁.norms), length(sys.kryvals₁.norms))
    for i in 1:length(sys.kryvals₁.norms), j in 1:length(sys.kryvals₁.norms)
        gf₁, gf₂ = LehmannGreenFunction(+1, sys.kryvals₁, sys.gsenergy, j, i), LehmannGreenFunction(-1, sys.kryvals₂, sys.gsenergy, i, j)
        gfm[i, j] = gf₁(ω, μ, η) + gf₂(ω, μ, η)
    end
    return gfm
end

"""
    differQuadraticTerms(ogen::OperatorGenerator, rgen::OperatorGenerator, table::Table, k::AbstractVector) -> Matrix

Calculate the difference between the Hamiltonian's quadratic terms of the original system and a reference system
"""
function differQuadraticTerms(ogen::OperatorGenerator, rgen::OperatorGenerator, table::Table, k::AbstractVector)
    om, rm = (zeros(Complex, length(table), length(table)), zeros(Complex, length(table), length(table)))
    oops, rops = filter(op -> length(op) == 2, collect(expand(ogen))), filter(op -> length(op) == 2, collect(expand(rgen)))
    for oop in oops
        seq₁, seq₂ = table[oop[1].index'], table[oop[2].index]
        phase = exp(im*dot(k, icoordinate(oop)))
        om[seq₁, seq₂] += oop.value*phase
    end
    for rop in rops 
        seq₁, seq₂ = table[rop[1].index'], table[rop[2].index]
        rm[seq₁, seq₂] += rop.value
    end
    return om - rm
end

"""
    Perioder
    Perioder(unitcell::AbstractLattice, cluster::AbstractLattice, table::Table)

User should ensure that the cluster you choosed is compatible with the lattice generated by the unitcell you input and the unitcell you input should be enclosed in the cluster you choosed sharing an original point with the cluster.

"""
struct Perioder
    map₁::Vector{AbstractVector}
    map₂::Vector{AbstractVector}
end 
function Perioder(unitcell::AbstractLattice, cluster::AbstractLattice, table::Table)
    @assert !isempty(unitcell.vectors) "the vectors in unitcell cannot be empty !"
    seq₁ = sort(collect(keys(table)), by = x -> table[x])
    map₁ = [Vector{Int}() for _ in 1:length(cluster)] 
    map₂ = [Vector{Int}() for _ in 1:length(unitcell)]
    for i in 1:length(cluster)
        for j in eachindex(seq₁)
            if i == seq₁[j][2]
                push!(map₁[i], j)
            end
        end
    end
    for i in 1:length(unitcell)
        for j in 1:length(cluster)
            if issubordinate(cluster.coordinates[:,j]-unitcell.coordinates[:,i], unitcell.vectors) 
                push!(map₂[i], j)
            end
        end
    end
    return Perioder(map₁, map₂)
end


"""
    VCA <: Frontend

Variational Cluster Approach(VCA) method for a quantum lattice system.
"""
struct VCA <: Frontend
    unitcell::AbstractLattice
    cluster::AbstractLattice
    origigenerator::OperatorGenerator
    refergenerator::OperatorGenerator
    solver::GFSolver
    perioder::Perioder
end

"""
    VCA(unitcell::AbstractLattice, cluster::AbstractLattice, hilbert₁::Hilbert, hilbert₂::Hilbert, origiterms::Tuple{Vararg{Term}}, referterms::Tuple{Vararg{Term}}, target::TargetSpace; neighbors::Neighbors, m::Int=200)

Construct the Variational Cluster Approach(VCA) method for a quantum lattice system with EDSolver
"""
function VCA(unitcell::AbstractLattice, cluster::AbstractLattice, hilbert₁::Hilbert, hilbert₂::Hilbert, origiterms::Tuple{Vararg{Term}}, referterms::Tuple{Vararg{Term}}, target::TargetSpace; neighbors::Neighbors, m::Int=200)
    k = EDKind(typeof(origiterms))
    table₁, table₂ = Table(hilbert₁, Metric(k, hilbert₁)), Table(hilbert₂, Metric(k, hilbert₂))
    origibonds = bonds(cluster, neighbors)
    referbonds = filter(bond -> isintracell(bond), origibonds)
    origigenerator, refergenerator = OperatorGenerator(origiterms, origibonds, hilbert₂; table = table₂), OperatorGenerator(referterms, referbonds, hilbert₂; table = table₂) 
    edsolver = EDSolver(k, refergenerator, target, table₂; m = m)
    perioder = Perioder(unitcell, cluster, table₂)
    return VCA(unitcell, cluster, origigenerator, refergenerator, edsolver, perioder)
end

"""
    VCA

Construct the Variational Cluster Approach(VCA) method for a quantum lattice system with QMCSolver
"""
function VCA(qmcsolver::QMCSolver)
    #to be update
end

"""
    VCAGreenFunction(vca::VCA, path::ReciprocalPath, CGFm::AbstractMatrix)

Calculate the Causal Green Function with VCA method in a certain path of a reciprocal space  
"""
function VCAGreenFunction(vca::VCA, path::ReciprocalPath, CGFm::AbstractMatrix) 
    M, L, N = length(vca.unitcell), length(vca.cluster), length(vca.origigenerator.table)
    GFpath = Vector{Matrix}()
    for p in eachindex(path)
        Im, LGFm, PGFm = Matrix{Complex}(I, N, N), zeros(Complex, L, L), zeros(Complex, M, M)
        Vm = differQuadraticTerms(vca.origigenerator, vca.refergenerator, vca.refergenerator.table, path[p])
        GFm = CGFm*inv(Im - Vm*CGFm)
        for i in 1:L, j in 1:L
            LGFm[i, j] = sum(GFm[vca.perioder.map₁[i], vca.perioder.map₁[j]])*exp(-im*dot(path[p], (vca.cluster.coordinates[:,i] - vca.cluster.coordinates[:,j])))
        end
        for i in 1:M, j in 1:M
            PGFm[i, j] = (1/(L/M))*sum(LGFm[vca.perioder.map₂[i], vca.perioder.map₂[j]])
        end
        push!(GFpath, PGFm)
    end
    return GFpath
end 

"""
    singleparticlespectrum(vca::VCA, k_path::ReciprocalPath, ω_range::AbstractRange, μ::Real)

Construct the k-ω matrix to store the data of single particle spectrum
"""
function singleparticlespectrum(vca::VCA, k_path::ReciprocalPath, ω_range::AbstractRange, μ::Real; η::Real=0.05)
    A = zeros(Float64, length(ω_range), length(k_path))
    for i in eachindex(ω_range)
        CGFm = clusterGreenFunction(vca.solver, ω_range[i], μ, η)
        GFpath = VCAGreenFunction(vca, k_path, CGFm)
        for j in eachindex(GFpath)
            A[i, j] = (-1/π)*imag(sum(GFpath[j]))
        end
    end
    return A
end

function statedensity(vca::VCA, k_path::ReciprocalPath, ω_range::AbstractRange, μ::Real; η::Real=0.05)
    A = singleparticlespectrum(vca, k_path, ω_range, μ; η = η)
    S = sum(A, dims=2)
    return S
end

"""
    saveData(data, filename::String) -> .jls

save data(e.g. a VCA data) as a jls file
"""
function saveData(data, filename::String)
    open(filename, "w") do io
        serialize(io, data)
    end
end

"""
    loadData(filename::String)

load data from a jls file
"""
function loadData(filename::String)
    data = nothing
    open(filename, "r") do io
        data = deserialize(io)
    end
    return data
end


end # module CPTVCA

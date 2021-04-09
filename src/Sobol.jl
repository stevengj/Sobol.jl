module Sobol
using Random
export SobolSeq, ScaledSobolSeq, next!

include("soboldata.jl") #loads `sobol_a` and `sobol_minit`

abstract type AbstractSobolSeq{N} end

# N iis the dimension of sequence being generated
mutable struct SobolSeq{N} <: AbstractSobolSeq{N}
    m::Array{UInt32,2} #array of size (sdim, 32)
    x::Array{UInt32,1} #previous x = x_n, array of length sdim
    b::Array{UInt32,1} #position of fixed point in x[i] is after bit b[i]
    n::UInt32 #number of x's generated so far
end

ndims(s::AbstractSobolSeq{N}) where {N} = N::Int

function SobolSeq(N::Int)
    (N < 0 || N > (length(sobol_a) + 1)) && error("invalid Sobol dimension")

    m = ones(UInt32, (N, 32))

    #special cases
    N == 0 && return(SobolSeq{0})(m,UInt32[],UInt32[],zero(UInt32))
    #special cases 1
    N == 1 && return(SobolSeq{N}(m,UInt32[0],UInt32[0],zero(UInt32)))

    for i = 2:N
        a = sobol_a[i-1]
        d = floor(Int, log2(a)) #degree of poly

        #set initial values of m from table
        m[i, 1:d] = sobol_minit[1:d, i - 1]
        #fill in remaining values using recurrence
        for j = (d+1):32
            ac = a
            m[i,j] = m[i,j-d]
            for k = 0:d-1
                @inbounds m[i,j] = m[i,j] ⊻ (((ac & one(UInt32)) * m[i, j-d+k]) << (d-k))
                ac >>= 1
            end
        end
    end
    SobolSeq{N}(m,zeros(UInt32,N),zeros(UInt32,N),zero(UInt32))
end
SobolSeq(N::Integer) = SobolSeq(Int(N))

function next!(s::SobolSeq, x::AbstractVector{<:AbstractFloat})
    length(x) != ndims(s) && throw(BoundsError())

    if s.n == typemax(s.n)
        return rand!(x)
    end

    s.n += one(s.n)
    c = UInt32(trailing_zeros(s.n))
    sb = s.b
    sx = s.x
    sm = s.m
    for i=1:ndims(s)
        @inbounds b = sb[i]
        # note: ldexp on Float64(sx[i]) is exact, independent of precision of x[i]
        if b >= c
            @inbounds sx[i] = sx[i] ⊻ (sm[i,c+1] << (b-c))
            @inbounds x[i] = ldexp(Float64(sx[i]), ((~b) % Int32))
        else
            @inbounds sx[i] = (sx[i] << (c-b)) ⊻ sm[i,c+1]
            @inbounds sb[i] = c
            @inbounds x[i] = ldexp(Float64(sx[i]), ((~c) % Int32))
        end
    end
    return x
end
next!(s::SobolSeq) = next!(s, Array{Float64,1}(undef, ndims(s)))

# if we know in advance how many points (n) we want to compute, then
# adopt a suggestion similar to the Joe and Kuo paper, which in turn
# is taken from Acworth et al (1998), of skipping a number of
# points one less than the largest power of 2 smaller than n+1.
# if exactly n points are to be skipped, use the keyword exact=true.
# (Ackworth and Joe and Kuo seem to suggest skipping exactly
#  a power of 2, but skipping 1 less seems to produce much better
#  results: issue #21.)
#
# skip!(s, n) skips 2^m - 1 such that 2^m < n ≤ 2^(m+1)
# skip!(s, n, exact=true) skips m = n

function skip!(s::SobolSeq, n::Integer, x; exact=false)
    n ≤ 0 && return s
    nskip = exact ? n : (1 << floor(Int,log2(n+1)) - 1)
    for unused=1:nskip; next!(s,x); end
    return s
end
Base.skip(s::SobolSeq, n::Integer; exact=false) = skip!(s, n, Array{Float64,1}(undef, ndims(s)); exact=exact)

function Base.show(io::IO, s::SobolSeq)
    print(io, "$(ndims(s))-dimensional Sobol sequence on [0,1]^$(ndims(s))")
end
function Base.show(io::IO, ::MIME"text/html", s::SobolSeq)
    print(io, "$(ndims(s))-dimensional Sobol sequence on [0,1]<sup>$(ndims(s))</sup>")
end

# Make an iterator so that we can do "for x in SobolSeq(...)".
# Technically, the Sobol sequence ends after 2^32-1 points, but it
# falls back on pseudorandom numbers after this.  In practice, one is
# unlikely to reach that point.
Base.iterate(s::AbstractSobolSeq, state=nothing) = (next!(s), state)
Base.eltype(::Type{<:AbstractSobolSeq}) = Vector{Float64}
Base.IteratorSize(::Type{<:AbstractSobolSeq}) = Base.IsInfinite()
Base.IteratorEltype(::Type{<:AbstractSobolSeq}) = Base.HasEltype()

# Convenience wrapper for scaled Sobol sequences

struct ScaledSobolSeq{N,T} <: AbstractSobolSeq{N}
    s::SobolSeq{N}
    lb::Vector{T}
    ub::Vector{T}
    function ScaledSobolSeq{N,T}(lb::Vector{T}, ub::Vector{T}) where {N,T}
        length(lb)==length(ub)==N || throw(DimensionMismatch("lb and ub do not have length $N"))
        new(SobolSeq(N), lb, ub)
    end
end
function SobolSeq(N::Integer, lb, ub)
    T = typeof(sum(ub) - sum(lb))
    ScaledSobolSeq{Int(N),T}(copyto!(Vector{T}(undef,N), lb), copyto!(Vector{T}(undef,N), ub))
end
SobolSeq(lb, ub) = SobolSeq(length(lb), lb, ub)

function next!(s::SobolSeq, x::AbstractVector{<:AbstractFloat},
               lb::AbstractVector, ub::AbstractVector)
    length(x) < ndims(s) && throw(BoundsError())
    next!(s,x)
    for i=1:ndims(s)
        x[i] = lb[i] + (ub[i]-lb[i]) * x[i]
    end
    return x
end
function next!(s::SobolSeq{N}, lb::AbstractVector, ub::AbstractVector) where {N}
    T = typeof(float((zero(eltype(ub)) - zero(eltype(lb)))))
    next!(s, Vector{T}(undef, N), lb, ub)
end

next!(s::ScaledSobolSeq, x::AbstractVector{<:AbstractFloat}) = next!(s.s, x, s.lb, s.ub)
next!(s::ScaledSobolSeq{N,T}) where {N,T} = next!(s.s, Vector{float(T)}(undef, N), s.lb, s.ub)
Base.eltype(::Type{ScaledSobolSeq{N,T}}) where {N,T} = Vector{float(T)}

Base.skip(s::ScaledSobolSeq, n; exact = false) = (skip(s.s, n; exact = exact); s)

function Base.show(io::IO, s::ScaledSobolSeq{N,T}) where {N,T}
    lb = s.lb; ub = s.ub
    print(io, "$N-dimensional scaled $(float(T)) Sobol sequence on [$(lb[1]),$(ub[1])]")
    cnt = 1
    for i = 2:N
        if lb[i] == lb[i-1] && ub[i] == ub[i-1]
            cnt += 1
        else
            if cnt > 1
                print(io, "^", cnt)
            end
            print(io, " x [", lb[i], ",", ub[i], "]")
            cnt = 1
        end
    end
    if cnt > 1
        print(io, "^", cnt)
    end
end

function Base.show(io::IO, ::MIME"text/html", s::ScaledSobolSeq{N,T}) where {N,T}
    lb = s.lb; ub = s.ub
    print(io, "$N-dimensional scaled $(float(T)) Sobol sequence on [$(lb[1]),$(ub[1])]")
    cnt = 1
    for i = 2:N
        if lb[i] == lb[i-1] && ub[i] == ub[i-1]
            cnt += 1
        else
            if cnt > 1
                print(io, "<sup>", cnt, "</sup>")
            end
            print(io, " × [", lb[i], ",", ub[i], "]")
            cnt = 1
        end
    end
    if cnt > 1
        print(io, "<sup>", cnt, "</sup>")
    end
end


end # module

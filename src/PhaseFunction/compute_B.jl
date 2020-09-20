using Revise
using RadiativeTransfer
using RadiativeTransfer.PhaseFunction


using Plots
using JLD2
using Distributions
using BenchmarkTools
using LinearAlgebra
using KernelAbstractions
using SparseArrays
using ..Architectures: device
using ..Architectures: devi
using CUDA

# Eqn. 1, averaged over size distribution
function compute_avg_C_scatt(k, an, bn, w)
    n_ = collect(1:size(an)[2]);
    n_ = 2n_ .+ 1
    return 2π/k^2 * n_' * (w' * (abs2.(an') + abs2.(bn'))')'
end

# Convenience function to compute all an, bn
function compute_anbn(aerosol::UnivariateAerosol, wl, radius)
    
    FT = eltype(radius)

    # Find overall N_max from the maximum radius
    N_max = PhaseFunction.get_n_max(2 * π * aerosol.r_max/ wl)

    # Where to store an, bn, computed over size distribution
    an = zeros(Complex{Float64}, aerosol.nquad_radius, N_max)
    bn = zeros(Complex{Float64}, aerosol.nquad_radius, N_max)

    # Loop over the size distribution, and compute an, bn, for each size
    for i in 1:aerosol.nquad_radius

        # Get current radius and size parameter
        r = radius[i] 
        size_param = 2 * π * r / wl

        # Pre-allocate Dn:
        y = size_param * (aerosol.nᵣ-aerosol.nᵢ);
        nmx = round(Int, max(N_max, abs(y))+51 )
        Dn = zeros(Complex{FT},nmx)

        # Compute an, bn
        PhaseFunction.compute_mie_ab!(size_param, aerosol.nᵣ + aerosol.nᵢ * im, 
                                      view(an, i, :), 
                                      view(bn, i, :), Dn)
    end

    return an, bn;
end

function compute_B(aerosol::UnivariateAerosol, wigner_A, wigner_B, wl, r, w)

    # Find overall N_max from the maximum radius
    N_max = PhaseFunction.get_n_max(2 * π * aerosol.r_max/ wl)

    # Compute an, bn values
    an, bn = compute_anbn(aerosol::UnivariateAerosol, wl, r)

    # Compute the average cross-sectional scattering
    k = 2 * π / wl

    avg_C_scatt = compute_avg_C_scatt(k, an, bn, w)

    # Only do these l's for now
    ls = 1:(2 * N_max - 1)

    # Where to store the values
    greek_coefs = zeros(6, size(ls, 1))

    # Pre-compute anbn averages
    FT2 = Complex{Float64}
    mat_anam = LowerTriangular(zeros(FT2, N_max, N_max));
    mat_bnbm = LowerTriangular(zeros(FT2, N_max, N_max));
    mat_anbm = LowerTriangular(zeros(FT2, N_max, N_max));
    mat_bnam = LowerTriangular(zeros(FT2, N_max, N_max));
    
    N_max_ = PhaseFunction.get_n_max.(2π * r/ wl)
    #PhaseFunction.fill_avg_anbns!(an, bn, mat_anam, mat_bnbm, mat_anbm, mat_bnam, w, N_max, N_max_, CPU())
    PhaseFunction.compute_avg_anbn!(an, bn, mat_anam, mat_bnbm, mat_anbm, mat_bnam, w, N_max, N_max_)
    an_m_bn = transpose(abs2.(an-bn)) * w
    an_p_bn = transpose(abs2.(an+bn)) * w
    # For each l
    @showprogress 1 "Computing S functions ..." for l in ls

        # Compute β_l
        #println(l)

        Sl_00  = compute_Sl(l, 0, 0,  true,  k, N_max, an,bn, mat_anam, mat_bnbm, mat_anbm, mat_bnam, wigner_A, wigner_B,an_m_bn,an_p_bn, w)
        Sl_0m0 = compute_Sl(l, 0, 0,  false, k, N_max, an,bn, mat_anam, mat_bnbm, mat_anbm, mat_bnam, wigner_A, wigner_B,an_m_bn,an_p_bn, w)
        Sl_22  = compute_Sl(l, 2, 2,  true,  k, N_max, an,bn, mat_anam, mat_bnbm, mat_anbm, mat_bnam, wigner_A, wigner_B,an_m_bn,an_p_bn, w)
        Sl_2m2 = compute_Sl(l, 2, -2, false, k, N_max, an,bn, mat_anam, mat_bnbm, mat_anbm, mat_bnam, wigner_A, wigner_B,an_m_bn,an_p_bn, w)
        Sl_02  = compute_Sl(l, 0, 2,  true,  k, N_max, an,bn, mat_anam, mat_bnbm, mat_anbm, mat_bnam, wigner_A, wigner_B,an_m_bn,an_p_bn, w)

        @inbounds greek_coefs[1,l] = (1/avg_C_scatt) * (Sl_00 + Sl_0m0)
        @inbounds greek_coefs[2,l] = (1/avg_C_scatt) * (Sl_00 - Sl_0m0)
        @inbounds greek_coefs[3,l] = (1/avg_C_scatt) * (Sl_22 + Sl_2m2)
        @inbounds greek_coefs[4,l] = (1/avg_C_scatt) * (Sl_22 - Sl_2m2)
        @inbounds greek_coefs[5,l] = (1/avg_C_scatt) * real(Sl_02)
        @inbounds greek_coefs[6,l] = (1/avg_C_scatt) * imag(Sl_02)
    end

    return greek_coefs

end

function test_B(wigner_A, wigner_B)

    # Constants
    μ  = 0.3
    σ  = 6.82
    wl = 0.55
    FT = Float64

    size_distribution = LogNormal(log(μ), log(σ))

    # Generate aerosol:
    aero = PhaseFunction.UnivariateAerosol(size_distribution, 30.0, 2500, 1.3, 0.0)
    r, wᵣ = PhaseFunction.gauleg(aero.nquad_radius, 0.0, aero.r_max ; norm=true)
    wₓ = pdf.(aero.size_distribution,r)
    # pre multiply with wᵣ to get proper means eventually:
    wₓ .*= wᵣ
    # normalize (could apply a check whether cdf.(aero.size_distribution,r_max) is larger than 0.99:
    wₓ /= sum(wₓ)

    N_max = PhaseFunction.get_n_max(2 * π * aero.r_max/ wl)

     

    return compute_B(aero, wigner_A, wigner_B, wl, r, wₓ)
end

### 
### If you want to compute the wigner symbols and save them to file: 
### 

# N_max = 400
# wigner_A, wigner_B = PhaseFunction.compute_wigner_values((2 * N_max + 1), N_max + 1, 2 * N_max + 1)
# PhaseFunction.save_wigner_values("/home/rjeyaram/RadiativeTransfer/src/PhaseFunction/wigner_values_sparse.jld", wigner_A, wigner_B)

### 
### If the wigner symbols are saved, load them from file: 
### 

# wigner_A, wigner_B = PhaseFunction.load_wigner_values("/home/rjeyaram/RadiativeTransfer/src/PhaseFunction/wigner_values.jld") 

# N_max = 400
# wigner_A, wigner_B = PhaseFunction.compute_wigner_values((2 * N_max + 1), N_max + 1, 2 * N_max + 1)
# PhaseFunction.save_wigner_values("/home/rjeyaram/RadiativeTransfer/src/PhaseFunction/wigner_values.jld", wigner_A, wigner_B)
# greek_coefs = test_B() 
wigner_A, wigner_B = PhaseFunction.load_wigner_values("/home/rjeyaram/RadiativeTransfer/src/PhaseFunction/wigner_values.jld")
@time greek_coefs = test_B(wigner_A, wigner_B)

α = greek_coefs[3,:]
β = greek_coefs[1,:]
γ = greek_coefs[5,:]
δ = greek_coefs[2,:]
ϵ = greek_coefs[6,:]
ζ = greek_coefs[4,:]

N_max = PhaseFunction.get_n_max(2 * π * 30.0/ 0.55)
n_mu = 2*N_max-1;

μ, w_μ = gausslegendre( n_mu )

# μs = -0.99:0.01:0.99

# μ = gausslegendre( 2 * 700 + 1 )

f₁₁, f₁₂, f₂₂, f₃₃, f₃₄, f₄₄ = PhaseFunction.reconstruct_phase(α, β, γ, δ, ϵ, ζ, μ)

plot(vcat(acos.(μ), acos.(-μ) + 3.141592653589 * ones(n_mu)), vcat(f₁₁, f₁₁), proj=:polar,  lims=(0,14))
# plot(acos.(μ), f₁₁, proj=:polar)
plot(μs, log.(f₁₁))
# , lims=(0,14),lw=10

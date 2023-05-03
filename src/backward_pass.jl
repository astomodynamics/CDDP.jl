"""
    backward_pass_ilqr()
"""
function backward_pass_ilqr!(
    sol::DDPSolutions,
    prob::iLQRProblem,
    params::DDPParameter,
)
    X, U = sol.X, sol.U
    dt = prob.dt
    reg_param1 = params.reg_param1
    reg_param2 = params.reg_param2

    # initialize arrays for backward pass
    ∇ₓf_arr::Vector{Matrix{Float64}} = Vector[]
    ∇ᵤf_arr::Vector{Matrix{Float64}} = Vector[]

    ell_arr::Vector{Float64} = Vector[]
    ∇ₓell_arr::Vector{Vector{Float64}} = Vector[]
    ∇ᵤell_arr::Vector{Vector{Float64}} = Vector[]
    ∇ₓₓell_arr::Vector{Matrix{Float64}} = Vector[]
    ∇ₓᵤell_arr::Vector{Matrix{Float64}} = Vector[]
    ∇ᵤᵤell_arr::Vector{Matrix{Float64}} = Vector[]

    l_arr::Vector{Vector{Float64}} = Vector[]
    L_arr::Vector{Matrix{Float64}} = Vector[]

    # store dynamics and cost information
    for k in 0:prob.tN-1
        t = k * dt
        x, u = X(t), U(t)

        ∇ₓf, ∇ᵤf = get_ode_derivatives(prob, x, u, t, isilqr=true)

        # store dynamics information
        push!(∇ₓf_arr, I + ∇ₓf * dt)
        push!(∇ᵤf_arr, ∇ᵤf * dt)

        ell = prob.ell(x, u, prob.x_final)
        ∇ₓell, ∇ᵤell, ∇ₓₓell, ∇ₓᵤell, ∇ᵤᵤell = get_instant_cost_derivatives(prob.ell, x, u, prob.x_final)

        # store cost information
        push!(ell_arr, ell)
        push!(∇ₓell_arr, ∇ₓell)
        push!(∇ᵤell_arr, ∇ᵤell)
        push!(∇ₓₓell_arr, ∇ₓₓell)
        push!(∇ₓᵤell_arr, ∇ₓᵤell)
        push!(∇ᵤᵤell_arr, ∇ᵤᵤell)
    end

    ϕ = prob.ϕ(X(prob.tf), prob.x_final)
    ∇ₓϕ, ∇ₓₓϕ = get_terminal_cost_derivatives(prob.ϕ, X(prob.tf), prob.x_final)

    # value function and its derivatives
    V = copy(ϕ)
    ∇ₓV = copy(∇ₓϕ)
    ∇ₓₓV = copy(∇ₓₓϕ)

    # backward pass
    for k in length(ell_arr):-1:1
        Q = ell_arr[k] + V
        ∇ₓQ = ∇ₓell_arr[k] + ∇ₓf_arr[k]' * ∇ₓV
        ∇ᵤQ = ∇ᵤell_arr[k] + ∇ᵤf_arr[k]' * ∇ₓV

        ∇ₓₓQ = ∇ₓₓell_arr[k] + ∇ₓf_arr[k]' * (∇ₓₓV + reg_param1 * I) * ∇ₓf_arr[k]
        ∇ₓᵤQ = ∇ₓᵤell_arr[k] + ∇ₓf_arr[k]' * (∇ₓₓV + reg_param1 * I) * ∇ᵤf_arr[k]
        ∇ᵤᵤQ = ∇ᵤᵤell_arr[k] + ∇ᵤf_arr[k]' * (∇ₓₓV + reg_param1 * I) * ∇ᵤf_arr[k]
        ∇ᵤᵤQ += reg_param2 * I

        gains_mat = Matrix[]
        try
            C = cholesky(Hermitian(∇ᵤᵤQ)) # Cholesky factorization for accelerating computation
            U = C.U
            gains_mat = -U \ (U' \ [∇ᵤQ ∇ₓᵤQ'])
            # NOTE: the following operation is as fast as cholesky...
            # M_gain = -∇ᵤᵤQ \ [∇ᵤQ  ∇ₓᵤQ'] 
        catch err
            @printf("∇ᵤᵤQ matrix is not positive definite. Consider changing reglarization parameters")
            @error "ERROR: " exception = (err, catch_backtrace())
        end
        # compute feedback and feedforward gains
        l = gains_mat[:, 1]
        L = gains_mat[:, 2:end]
        # update values of gradient and hessian of the value function
        V += 0.5 * l' * ∇ᵤᵤQ * l + l' * ∇ᵤQ
        ∇ₓV = ∇ₓQ + L' * ∇ᵤQ + L' * ∇ᵤᵤQ * l + ∇ₓᵤQ * l
        ∇ₓₓV = ∇ₓₓQ + L' * ∇ₓᵤQ' + ∇ₓᵤQ * L + L' * ∇ᵤᵤQ * L

        # store feedforward and feedback gains
        push!(l_arr, l)
        push!(L_arr, L)
    end
    Tarr = collect(LinRange(0.0, prob.tf, prob.tN))
    l_func = linear_interpolation((Tarr,), reverse(l_arr), extrapolation_bc=Line())
    L_func = linear_interpolation((Tarr,), reverse(L_arr), extrapolation_bc=Line())
    sol.gains.l = l_func
    sol.gains.L = L_func
end



"""
    backward_pass_ddp()
"""
function backward_pass_ddp!(
    sol::DDPSolutions,
    prob::AbstractDDPProblem,
    params::DDPParameter,
    isilqr::Bool=false,
)
    X, U = sol.X, sol.U
    dt = prob.dt
    reg_param1 = params.reg_param1
    reg_param2 = params.reg_param2

    # initialize arrays for backward pass
    ∇ₓf_arr::Vector{Matrix{Float64}} = Vector[]
    ∇ᵤf_arr::Vector{Matrix{Float64}} = Vector[]
    ∇ₓₓf_arr::Vector{AbstractArray{Float64,3}} = Vector[]
    ∇ₓᵤf_arr::Vector{AbstractArray{Float64,3}} = Vector[]
    ∇ᵤᵤf_arr::Vector{AbstractArray{Float64,3}} = Vector[]

    ell_arr::Vector{Float64} = Vector[]
    ∇ₓell_arr::Vector{Vector{Float64}} = Vector[]
    ∇ᵤell_arr::Vector{Vector{Float64}} = Vector[]
    ∇ₓₓell_arr::Vector{Matrix{Float64}} = Vector[]
    ∇ₓᵤell_arr::Vector{Matrix{Float64}} = Vector[]
    ∇ᵤᵤell_arr::Vector{Matrix{Float64}} = Vector[]

    l_arr::Vector{Vector{Float64}} = Vector[]
    L_arr::Vector{Matrix{Float64}} = Vector[]

    # store dynamics and cost information
    for k in 0:prob.tN-1
        t = k * dt
        x, u = X(t), U(t)

        if isilqr
            ∇ₓf, ∇ᵤf = get_ode_derivatives(prob, x, u, t, isilqr=isilqr)

            # store dynamics information
            push!(∇ₓf_arr, I + ∇ₓf * dt)
            push!(∇ᵤf_arr, ∇ᵤf * dt)
        else
            ∇ₓf, ∇ᵤf, ∇ₓₓf, ∇ₓᵤf, ∇ᵤᵤf = get_ode_derivatives(prob, x, u, t, isilqr=isilqr)

            # store dynamics information
            push!(∇ₓf_arr, I + ∇ₓf * dt)
            push!(∇ᵤf_arr, ∇ᵤf * dt)
            push!(∇ₓₓf_arr, ∇ₓₓf * dt)
            push!(∇ₓᵤf_arr, ∇ₓᵤf * dt)
            push!(∇ᵤᵤf_arr, ∇ᵤᵤf * dt)
        end

        ell = prob.ell(x, u, prob.x_final)
        ∇ₓell, ∇ᵤell, ∇ₓₓell, ∇ₓᵤell, ∇ᵤᵤell = get_instant_cost_derivatives(prob.ell, x, u, prob.x_final)

        # store cost information
        push!(ell_arr, ell)
        push!(∇ₓell_arr, ∇ₓell)
        push!(∇ᵤell_arr, ∇ᵤell)
        push!(∇ₓₓell_arr, ∇ₓₓell)
        push!(∇ₓᵤell_arr, ∇ₓᵤell)
        push!(∇ᵤᵤell_arr, ∇ᵤᵤell)
    end

    ϕ = prob.ϕ(X(prob.tf), prob.x_final)
    ∇ₓϕ, ∇ₓₓϕ = get_terminal_cost_derivatives(prob.ϕ, X(prob.tf), prob.x_final)

    # value function and its derivatives
    V = copy(ϕ)
    ∇ₓV = copy(∇ₓϕ)
    ∇ₓₓV = copy(∇ₓₓϕ)

    # backward pass
    for k in length(ell_arr):-1:1
        Q = ell_arr[k] + V
        ∇ₓQ = ∇ₓell_arr[k] + ∇ₓf_arr[k]' * ∇ₓV
        ∇ᵤQ = ∇ᵤell_arr[k] + ∇ᵤf_arr[k]' * ∇ₓV

        ∇ₓₓQ = ∇ₓₓell_arr[k] + ∇ₓf_arr[k]' * (∇ₓₓV + reg_param1 * I) * ∇ₓf_arr[k]
        ∇ₓᵤQ = ∇ₓᵤell_arr[k] + ∇ₓf_arr[k]' * (∇ₓₓV + reg_param1 * I) * ∇ᵤf_arr[k]
        ∇ᵤᵤQ = ∇ᵤᵤell_arr[k] + ∇ᵤf_arr[k]' * (∇ₓₓV + reg_param1 * I) * ∇ᵤf_arr[k]

        if !isilqr
            for j = 1:prob.x_dim
                ∇ₓₓQ += ∇ₓV[j] .* ∇ₓₓf_arr[k][j, :, :]
                ∇ₓᵤQ += ∇ₓV[j] .* ∇ₓᵤf_arr[k][j, :, :]
                ∇ᵤᵤQ += ∇ₓV[j] .* ∇ᵤᵤf_arr[k][j, :, :]
            end
        end

        ∇ᵤᵤQ += reg_param2 * I

        gains_mat = Matrix[]
        # try
        #     C = cholesky(Hermitian(∇ᵤᵤQ)) # Cholesky factorization for accelerating computation
        #     Upper = C.U
        #     gains_mat = -Upper \ (Upper' \ [∇ᵤQ ∇ₓᵤQ'])
        #     # NOTE: the following operation is as fast as cholesky...
        #     # M_gain = -∇ᵤᵤQ \ [∇ᵤQ  ∇ₓᵤQ'] 
        # catch err
        #     @printf("∇ᵤᵤQ matrix is not positive definite. Consider changing reglarization parameters")
        #     @error "ERROR: " exception = (err, catch_backtrace())
        # end

        gains_mat = -∇ᵤᵤQ \ [∇ᵤQ  ∇ₓᵤQ'] 
        # compute feedback and feedforward gains
        l = gains_mat[:, 1]
        L = gains_mat[:, 2:end]

        # update values of gradient and hessian of the value function
        V += 0.5 * l' * ∇ᵤᵤQ * l + l' * ∇ᵤQ
        ∇ₓV = ∇ₓQ + L' * ∇ᵤQ + L' * ∇ᵤᵤQ * l + ∇ₓᵤQ * l
        ∇ₓₓV = ∇ₓₓQ + L' * ∇ₓᵤQ' + ∇ₓᵤQ * L + L' * ∇ᵤᵤQ * L

        # store feedforward and feedback gains
        push!(l_arr, l)
        push!(L_arr, L)
    end
    Tarr = collect(LinRange(0.0, prob.tf, prob.tN))
    l_func = linear_interpolation((Tarr,), reverse(l_arr), extrapolation_bc=Line())
    L_func = linear_interpolation((Tarr,), reverse(L_arr), extrapolation_bc=Line())
    sol.gains.l = l_func
    sol.gains.L = L_func
end


"""
    backward_pass_cddp()
"""
function backward_pass_cddp!(
    sol::DDPSolutions,
    prob::AbstractDDPProblem,
    params::CDDPParameter;
    isilqr::Bool=false
)
    X, U, Λ, Y = sol.X, sol.U, sol.Λ, sol.Y
    dt = prob.dt
    reg_param1 = params.reg_param1
    reg_param2 = params.reg_param2
    μip = params.μip

    # initialize arrays for backward pass
    ∇ₓf_arr::Vector{Matrix{Float64}} = Vector[]
    ∇ᵤf_arr::Vector{Matrix{Float64}} = Vector[]
    ∇ₓₓf_arr::Vector{AbstractArray{Float64,3}} = Vector[]
    ∇ₓᵤf_arr::Vector{AbstractArray{Float64,3}} = Vector[]
    ∇ᵤᵤf_arr::Vector{AbstractArray{Float64,3}} = Vector[]

    ell_arr::Vector{Float64} = Vector[]
    ∇ₓell_arr::Vector{Vector{Float64}} = Vector[]
    ∇ᵤell_arr::Vector{Vector{Float64}} = Vector[]
    ∇ₓₓell_arr::Vector{Matrix{Float64}} = Vector[]
    ∇ₓᵤell_arr::Vector{Matrix{Float64}} = Vector[]
    ∇ᵤᵤell_arr::Vector{Matrix{Float64}} = Vector[]

    l_arr::Vector{Vector{Float64}} = Vector[]
    L_arr::Vector{Matrix{Float64}} = Vector[]
    m_arr::Vector{Vector{Float64}} = Vector[]
    M_arr::Vector{Matrix{Float64}} = Vector[]
    n_arr::Vector{Vector{Float64}} = Vector[]
    N_arr::Vector{Matrix{Float64}} = Vector[]

    # store dynamics and cost information
    for k in 0:prob.tN-1
        t = k * dt
        x, u = X(t), U(t)

        if isilqr
            ∇ₓf, ∇ᵤf = get_ode_derivatives(prob, x, u, t, isilqr=isilqr)

            # store dynamics information
            push!(∇ₓf_arr, I + ∇ₓf * dt)
            push!(∇ᵤf_arr, ∇ᵤf * dt)
        else
            ∇ₓf, ∇ᵤf, ∇ₓₓf, ∇ₓᵤf, ∇ᵤᵤf = get_ode_derivatives(prob, x, u, t, isilqr=isilqr)

            # store dynamics information
            push!(∇ₓf_arr, I + ∇ₓf * dt)
            push!(∇ᵤf_arr, ∇ᵤf * dt)
            push!(∇ₓₓf_arr, ∇ₓₓf * dt)
            push!(∇ₓᵤf_arr, ∇ₓᵤf * dt)
            push!(∇ᵤᵤf_arr, ∇ᵤᵤf * dt)
        end

        ell = prob.ell(x, u, prob.x_final)
        ∇ₓell, ∇ᵤell, ∇ₓₓell, ∇ₓᵤell, ∇ᵤᵤell = get_instant_cost_derivatives(prob.ell, x, u, prob.x_final)

        # store cost information
        push!(ell_arr, ell)
        push!(∇ₓell_arr, ∇ₓell)
        push!(∇ᵤell_arr, ∇ᵤell)
        push!(∇ₓₓell_arr, ∇ₓₓell)
        push!(∇ₓᵤell_arr, ∇ₓᵤell)
        push!(∇ᵤᵤell_arr, ∇ᵤᵤell)
    end

    ϕ = prob.ϕ(X(prob.tf), prob.x_final)
    ∇ₓϕ, ∇ₓₓϕ = get_terminal_cost_derivatives(prob.ϕ, X(prob.tf), prob.x_final)

    # value function and its derivatives
    V = copy(ϕ)
    ∇ₓV = copy(∇ₓϕ)
    ∇ₓₓV = copy(∇ₓₓϕ)

    # backward pass
    for k in length(ell_arr):-1:1
        t = k * dt
        x, u, λ, y = X(t), U(t), Λ(t), Y(t)

        Q = ell_arr[k] + V
        ∇ₓQ = ∇ₓell_arr[k] + ∇ₓf_arr[k]' * ∇ₓV
        ∇ᵤQ = ∇ᵤell_arr[k] + ∇ᵤf_arr[k]' * ∇ₓV

        ∇ₓₓQ = ∇ₓₓell_arr[k] + ∇ₓf_arr[k]' * (∇ₓₓV + reg_param1 * I) * ∇ₓf_arr[k]
        ∇ₓᵤQ = ∇ₓᵤell_arr[k] + ∇ₓf_arr[k]' * (∇ₓₓV + reg_param1 * I) * ∇ᵤf_arr[k]
        ∇ᵤᵤQ = ∇ᵤᵤell_arr[k] + ∇ᵤf_arr[k]' * (∇ₓₓV + reg_param1 * I) * ∇ᵤf_arr[k]

        if !isilqr
            for j = 1:prob.x_dim
                ∇ₓₓQ += ∇ₓV[j] .* ∇ₓₓf_arr[k][j, :, :]
                ∇ₓᵤQ += ∇ₓV[j] .* ∇ₓᵤf_arr[k][j, :, :]
                ∇ᵤᵤQ += ∇ₓV[j] .* ∇ᵤᵤf_arr[k][j, :, :]
            end
        end

        ∇ᵤᵤQ += reg_param2 * I # add regularization term
        
        c = prob.c(x, u)
        ∇ₓc, ∇ᵤc, ∇ₓₓc, ∇ₓᵤc, ∇ᵤᵤc = get_instant_const_derivative(prob.c, x, u)
        ∇λₓQ = copy(∇ₓc)
        ∇λᵤQ = copy(∇ᵤc)

        gains_mat = Matrix[]

        if params.isfeasible
            Diag_c = diagm(c) # diagonalize constraint functions
            Diag_λ = diagm(λ) # diagonalize Lagrange multiplier
            r = Diag_λ * c .+ μip # compute the remaining value
            Diag_c_inv = inv(Diag_c) # compute inverse of constraint matrix
            Diag_cInv_Diag_λ = Diag_c_inv * Diag_λ # compute multiplication of inverse and diagonal matrices
            ∇ᵤᵤQ -= ∇λᵤQ' * Diag_cInv_Diag_λ * ∇λᵤQ

            # action-value function update for constrained problem
            ∇ₓQ -= ∇λₓQ' * Diag_c_inv * r
            ∇ᵤQ -= ∇λᵤQ' * Diag_c_inv * r
            ∇ₓₓQ -= ∇λₓQ' * Diag_cInv_Diag_λ * ∇λₓQ
            ∇ₓᵤQ -= ∇λₓQ' * Diag_cInv_Diag_λ * ∇λᵤQ
            ∇ᵤᵤQ -= ∇λᵤQ' * Diag_cInv_Diag_λ * ∇λᵤQ

            gains_mat = -∇ᵤᵤQ \ [∇ᵤQ - ∇λᵤQ' * Diag_c_inv * r  ∇ₓᵤQ' - ∇λᵤQ' * Diag_cInv_Diag_λ * ∇λₓQ] 

            # compute feedback and feedforward gains
            l = gains_mat[:, 1]
            L = gains_mat[:, 2:end]
            m = Diag_c_inv * (r + Diag_λ * ∇λᵤQ * l)
            M = Diag_cInv_Diag_λ * (∇λₓQ + ∇λᵤQ * L)

            # update values of gradient and hessian of the value function
            V += 0.5 * l' * ∇ᵤᵤQ * l + l' * ∇ᵤQ
            ∇ₓV = ∇ₓQ + L' * ∇ᵤQ + L' * ∇ᵤᵤQ * l + ∇ₓᵤQ * l
            ∇ₓₓV = ∇ₓₓQ + L' * ∇ₓᵤQ' + ∇ₓᵤQ * L + L' * ∇ᵤᵤQ * L

            # store feedforward and feedback gains
            push!(l_arr, l)
            push!(L_arr, L)
            push!(m_arr, m)
            push!(M_arr, M)
            push!(n_arr, zeros(prob.λ_dim))
            push!(N_arr, zeros(prob.λ_dim, prob.x_dim))
        else
            Diag_y = diagm(y) # diagonalize constraint functions
            Diag_λ = diagm(λ) # diagonalize Lagrange multiplier
            r = Diag_λ * y .- μip # compute the remaining value
            r̂ = Diag_λ * (c + y) .- r
            Diag_y_inv = inv(Diag_y) # compute inverse of constraint matrix
            Diag_yInv_Diag_λ = Diag_y_inv * Diag_λ # compute multiplication of inverse and diagonal matrices
            ∇ᵤᵤQ += ∇λᵤQ' * Diag_yInv_Diag_λ * ∇λᵤQ

            # action-value function update for constrained problem
            ∇ₓQ += ∇λₓQ' * Diag_y_inv * r̂
            ∇ᵤQ += ∇λᵤQ' * Diag_y_inv * r̂
            ∇ₓₓQ += ∇λₓQ' * Diag_yInv_Diag_λ * ∇λₓQ
            ∇ₓᵤQ += ∇λₓQ' * Diag_yInv_Diag_λ * ∇λᵤQ
            ∇ᵤᵤQ += ∇λᵤQ' * Diag_yInv_Diag_λ * ∇λᵤQ

            gains_mat = -∇ᵤᵤQ \ [∇ᵤQ + ∇λᵤQ' * Diag_y_inv * r̂  ∇ₓᵤQ' + ∇λᵤQ' * Diag_yInv_Diag_λ * ∇λₓQ] 

            # compute feedback and feedforward gains
            l = gains_mat[:, 1]
            L = gains_mat[:, 2:end]
            m = Diag_y_inv * (r̂ + Diag_λ * ∇λᵤQ * l)
            M = Diag_yInv_Diag_λ * (∇λₓQ + ∇λᵤQ * L)
            n = -(c + y) - ∇λᵤQ * l
            N = -∇λₓQ - ∇λᵤQ * L
            
            # update values of gradient and hessian of the value function
            V += 0.5 * l' * ∇ᵤᵤQ * l + l' * ∇ᵤQ
            ∇ₓV = ∇ₓQ + L' * ∇ᵤQ + L' * ∇ᵤᵤQ * l + ∇ₓᵤQ * l
            ∇ₓₓV = ∇ₓₓQ + L' * ∇ₓᵤQ' + ∇ₓᵤQ * L + L' * ∇ᵤᵤQ * L

            # store feedforward and feedback gains
            push!(l_arr, l)
            push!(L_arr, L)
            push!(m_arr, m)
            push!(M_arr, M)
            push!(n_arr, n)
            push!(N_arr, N)
        end
    end

    Tarr = collect(LinRange(0.0, prob.tf, prob.tN))
    l_func = linear_interpolation((Tarr,), reverse(l_arr), extrapolation_bc=Line())
    L_func = linear_interpolation((Tarr,), reverse(L_arr), extrapolation_bc=Line())
    m_func = linear_interpolation((Tarr,), reverse(m_arr), extrapolation_bc=Line())
    M_func = linear_interpolation((Tarr,), reverse(M_arr), extrapolation_bc=Line())
    n_func = linear_interpolation((Tarr,), reverse(m_arr), extrapolation_bc=Line())
    N_func = linear_interpolation((Tarr,), reverse(M_arr), extrapolation_bc=Line())
    sol.gains.l = l_func
    sol.gains.L = L_func
    sol.gains.m = m_func
    sol.gains.M = M_func
    sol.gains.n = n_func
    sol.gains.N = N_func
    nothing
end
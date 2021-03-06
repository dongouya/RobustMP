clear all; close all; clc;
warning('off','MATLAB:nargchk:deprecated');
         
%% Load constants, dynamics, CCM, bounds, environment

load_PVTOL_config;

%% Load & initialize solvers

%choose if enabling mpc (local re-planning)
do_mpc = 1;
%choose if use time-varying tube for MPC
time_var = 1;

%initialize problem structs
load_solvers;

%% Visualize initial setup

visualize_PVTOL;

%% Set up non-linear sim
ode_options = odeset('RelTol', 1e-6, 'AbsTol', 1e-9);

%zero-order-hold for feedback controller
dt_sim = 0.002; 
t_end = Tp;
solve_t = (0:dt_sim:t_end)';
T_steps = length(solve_t)-1;

if (do_mpc)
    dt_MPC = delta;
    mpc_resolve_steps = round(delta/dt_sim);
    
    solve_MPC = (0:dt_MPC:t_end)';
    if solve_MPC(end)==t_end
        T_steps_MPC = length(solve_MPC)-1;
    else
        T_steps_MPC = length(solve_MPC);
    end
    
    %Store MPC solution
    MPC_state = cell(T_steps_MPC,1);
    MPC_ctrl = cell(T_steps_MPC,1);
    
    %MPC rejoin time
    MPC_time = zeros(T_steps_MPC,2);
    
end

%Store disturbance
w_dist = zeros(T_steps,2);

%Store actual state
X = zeros(T_steps+1,n);

%Store control history
U_fb = zeros(T_steps,m);
U = zeros((t_end/dt)+1,m);
U_nom = zeros((t_end/dt)+1,m);

%Computation times
ctrl_solve_time = zeros(T_steps,2);
ctrl_solve_time(:,1) = NaN;

%Solve success
opt_solved = NaN(T_steps,2);

%Geodesic distances
geo_energy = zeros(T_steps,2);
geo_energy(:,2) = NaN;

%Initialize
X(1,:) = test_state';
x = test_state;
x0_MPC = MP_state(1,:)';
u0_MPC = MP_ctrl(1,:)';

i_mpc = 0;
      
%% Simulate
disp('Ready to Simulate');
keyboard;

for i = 1:T_steps
    
    %Get nominal state and control
    if (do_mpc)
        %First Solve MPC
        if (mod(i-1,mpc_resolve_steps)==0)
            
            fprintf('%d/%d:',i,T_steps);
            
            %Get current dist off nominal
            [J_opt,~,geo_Prob,cntrl_info,~] = compute_CCM_controller(geo_Prob,cntrl_info,...
                x0_MPC,u0_MPC,x);
            geo_energy(i,1) = J_opt;
            
            if (i>1) && (obs_mpc.time_var)
                E_bnd = J_opt;
            else
                E_bnd = (d_bar)^2;
            end
            
            %Now solve MPC problem given current tube bound
            tic
            [MPC_x,MPC_u,mpc_T_rejoin,opt_solved(i,1),mpc_warm,MPC_Prob,~] = compute_LMP(MPC_Prob,...
                x,x_con,u_con,MP_t,MP_state,MP_ctrl,...
                n,m,N_mpc,L_e_mpc,mpc_warm,dt,solve_t(i),delta,E_bnd,lambda,obs_mpc);
            ctrl_solve_time(i,1) = toc;
            
            fprintf('MPC solved: %d, Solve time: %.2f \n', opt_solved(i,1),ctrl_solve_time(i,1));
            i_mpc = i_mpc + 1;
            
            %record solution
            MPC_state{i_mpc} = MPC_x;
            MPC_ctrl{i_mpc} = MPC_u;
            MPC_time(i_mpc,1) = solve_t(i);
            MPC_time(i_mpc,2) = mpc_T_rejoin;
            
            %extract current nominal
            x_nom = MPC_state{i_mpc}(1,:);
            u_nom = MPC_ctrl{i_mpc}(1:round(dt_sim/dt)+1,:);
            
            %update starting state&control for next MPC problem
            x0_MPC = MPC_state{i_mpc}(round(delta/dt)+1,:)';
            u0_MPC = MPC_ctrl{i_mpc}(round(delta/dt)+1,:)';
            
            %resolve geodesic to record new bound
            [J_opt,~,geo_Prob,cntrl_info,~] = compute_CCM_controller(geo_Prob,cntrl_info,...
                x_nom',u_nom(1,:)',x);
            geo_energy(i,2) = J_opt;
        else
            i_mpc_t = floor((mod(solve_t(i),delta))/dt)+1;
            x_nom = MPC_state{i_mpc}(i_mpc_t,:);
            u_nom = MPC_ctrl{i_mpc}(i_mpc_t:i_mpc_t+round(dt_sim/dt),:);
        end
    else
        if (mod(i,500)==0)
            fprintf('%d/%d\n',i,T_steps);
        end
        
        x_nom = MP_state(1+(i-1)*(dt_sim/dt),:);
        u_nom = MP_ctrl(1+(i-1)*(dt_sim/dt):1+i*(dt_sim/dt),:);
    end
    
    %Feedback control
    tic
    [J_opt,opt_solved(i,2),geo_Prob,cntrl_info,u_fb] = compute_CCM_controller(geo_Prob,cntrl_info,...
        x_nom',u_nom(1,:)',x);
    ctrl_solve_time(i,2) = toc;
    
    geo_energy(i,1) = J_opt;
    
    U_fb(i,:) = u_fb';
    U(1+(i-1)*(dt_sim/dt):1+i*(dt_sim/dt),:) = u_nom+repmat(U_fb(i,:),(dt_sim/dt)+1,1);
    U_nom(1+(i-1)*(dt_sim/dt):1+i*(dt_sim/dt),:) = u_nom;
    
    %Generate disturbance
    w_dist(i,:) = w_max*(sin(2*pi*(1/10)*solve_t(i)))*...
        [cos(X(i,3));
        -sin(X(i,3))]';
    
    %sim
    [~,d_state] = ode113(@(t,d_state)ode_sim(t,d_state,[solve_t(i):dt:solve_t(i+1)]',u_nom,U_fb(i,:),...
        f,B,B_w,w_dist(i,:)'),[solve_t(i),solve_t(i+1)],x,ode_options);
    
    %update
    x = d_state(end,:)';
    X(i+1,:) = x';
end

%% Plots

close all;
plot_PVTOL;

%% 

keyboard;

if (do_mpc)
    plot_PVTOL_movie;
end
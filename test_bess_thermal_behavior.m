function thermalTest = test_bess_thermal_behavior()
% TEST_BESS_THERMAL_BEHAVIOR
%
% Kulso tesztfuggveny a BESS pack homodell ellenorzesere.
%
% Nem modositja a bess_pack_model vagy lfp_cell fuggvenyeket.
% Pontosan a publikus interfeszen keresztul hasznalja oket:
%
%   bess_pack_model(..., 'init', ...)
%   bess_pack_model(..., 'run', ...)
%
% Cel:
%   - ellenorizni, hogy van-e holeadas a kornyezet fele
%   - ellenorizni, hogy nyugalmi allapotban a cella visszahul-e
%   - ellenorizni, hogy terheles alatt melegszik-e
%   - egyszeru energiamerleget kesziteni cella- es pack-szinten
%
% Jelkonvencio:
%   P_pack_req > 0  : kisutes
%   P_pack_req < 0  : toltes
%   P_pack_req = 0  : nyugalmi allapot

    close all;
    clc;

    fprintf('BESS thermal behavior test started.\n');

    % ---------------------------------------------------------------------
    % 1) Teszt BESS meret
    % ---------------------------------------------------------------------
    E_BESS_kWh = 600;       % pelda: 0.6 MWh BESS
    P_BESS_kW  = 300;       % 2 oras BESS -> kb. 0.5C

    dt_h = 5 / 60;          % 5 perces idolepes
    dt_s = dt_h * 3600;

    % ---------------------------------------------------------------------
    % 2) LFP cella alap homodell parameterek
    % Ezek megegyeznek az lfp_cell jelenlegi alapertelmezett ertekeivel.
    % ---------------------------------------------------------------------
    M_CELL_kg = 5.4;
    CP_J_per_kgK = 1100;
    C_TH_cell_J_per_K = M_CELL_kg * CP_J_per_kgK;
    R_TH_cell_K_per_W = 4.0;

    % ---------------------------------------------------------------------
    % 3) Pack inicializalas
    % ---------------------------------------------------------------------
    pack_params = struct();
    pack_params.target_energy_kWh = E_BESS_kWh;
    pack_params.max_power_W = P_BESS_kW * 1000;
    pack_params.initial_soc = 0.50;

    [pack_init_out, pack_state] = bess_pack_model( ...
        0, ...
        'init', ...
        pack_params, ...
        dt_h, ...
        []);

    Ns = pack_init_out.Ns;
    Np = pack_init_out.Np;
    nCells = Ns * Np;

    fprintf('Initialized BESS pack:\n');
    fprintf('  E_target_kWh       = %.1f kWh\n', E_BESS_kWh);
    fprintf('  P_max_kW           = %.1f kW\n', P_BESS_kW);
    fprintf('  Ns                 = %d\n', Ns);
    fprintf('  Np                 = %d\n', Np);
    fprintf('  Total cells        = %d\n', nCells);
    fprintf('  E_installed_kWh    = %.2f kWh\n', pack_init_out.E_installed_kWh);
    fprintf('  V_nominal_pack     = %.1f V\n\n', pack_init_out.V_nominal_pack);

    % ---------------------------------------------------------------------
    % 4) Kezdeti cellahomerseklet direkt magasabbra allitasa
    % ---------------------------------------------------------------------
    % Ez csak a teszt miatt kell:
    % ha P = 0 es T_cell > T_amb, akkor latni kell a lehulest.
    pack_state.cell_state.T_cell = 40;
    pack_state.cell_state.SOC = 0.50;

    % ---------------------------------------------------------------------
    % 5) Tesztprofil osszeallitasa
    % ---------------------------------------------------------------------
    % Szakaszok:
    %   A: 6 ora piheno, T_cell = 40 C, T_amb = 25 C
    %      -> hulesnek kell latszania
    %
    %   B: 2 ora kisutes +300 kW
    %      -> melegedes
    %
    %   C: 8 ora piheno
    %      -> hules
    %
    %   D: 2 ora toltes -300 kW
    %      -> melegedes
    %
    %   E: 12 ora piheno
    %      -> hules

    t_rest1_h = 6;
    t_dis_h   = 2;
    t_rest2_h = 8;
    t_ch_h    = 2;
    t_rest3_h = 12;

    n_rest1 = round(t_rest1_h / dt_h);
    n_dis   = round(t_dis_h   / dt_h);
    n_rest2 = round(t_rest2_h / dt_h);
    n_ch    = round(t_ch_h    / dt_h);
    n_rest3 = round(t_rest3_h / dt_h);

    P_pack_req_W = [ ...
        zeros(1, n_rest1), ...
        +P_BESS_kW * 1000 * ones(1, n_dis), ...
        zeros(1, n_rest2), ...
        -P_BESS_kW * 1000 * ones(1, n_ch), ...
        zeros(1, n_rest3)];

    N = numel(P_pack_req_W);

    T_amb_C = 25 * ones(1, N);

    time_h = (0:N-1) * dt_h;

    % ---------------------------------------------------------------------
    % 6) Pack futtatasa
    % ---------------------------------------------------------------------
    pack_params.T_vec = T_amb_C;

    [pack_out, pack_state_end] = bess_pack_model( ...
        P_pack_req_W, ...
        'run', ...
        pack_params, ...
        dt_h, ...
        pack_state);

    % ---------------------------------------------------------------------
    % 7) Kiolvasas
    % ---------------------------------------------------------------------
    T_cell_C = pack_out.T_cell(:).';
    SOC = pack_out.SOC(:).';

    E_loss_joule_Wh_pack = pack_out.E_loss_joule(:).';
    E_loss_sat_Wh_pack   = pack_out.E_loss_sat(:).';
    E_loss_empty_Wh_pack = pack_out.E_loss_empty(:).';

    P_loss_joule_pack_kW = E_loss_joule_Wh_pack / 1000 / dt_h;
    P_loss_sat_pack_kW   = E_loss_sat_Wh_pack   / 1000 / dt_h;
    P_loss_empty_pack_kW = E_loss_empty_Wh_pack / 1000 / dt_h;

    P_loss_total_pack_kW = ...
        P_loss_joule_pack_kW + ...
        P_loss_sat_pack_kW + ...
        P_loss_empty_pack_kW;

    % Cellaszintu veszteseg becsles
    P_loss_joule_cell_W = P_loss_joule_pack_kW * 1000 / nCells;

    % Homodell szerinti pillanatnyi cellaszintu holeadas
    q_conv_cell_W = (T_cell_C - T_amb_C) / R_TH_cell_K_per_W;

    % Pack-szintu holeadas, homogen cellafeltetelezessel
    q_conv_pack_kW = q_conv_cell_W * nCells / 1000;

    % ---------------------------------------------------------------------
    % 8) Ellenorzo mutatok
    % ---------------------------------------------------------------------
    idx_rest1 = 1:n_rest1;
    idx_dis   = (n_rest1+1):(n_rest1+n_dis);
    idx_rest2 = (n_rest1+n_dis+1):(n_rest1+n_dis+n_rest2);
    idx_ch    = (n_rest1+n_dis+n_rest2+1):(n_rest1+n_dis+n_rest2+n_ch);
    idx_rest3 = (n_rest1+n_dis+n_rest2+n_ch+1):N;

    T_start = T_cell_C(1);
    T_after_rest1 = T_cell_C(idx_rest1(end));
    T_after_dis = T_cell_C(idx_dis(end));
    T_after_rest2 = T_cell_C(idx_rest2(end));
    T_after_ch = T_cell_C(idx_ch(end));
    T_end = T_cell_C(end);

    cooling_rest1_C = T_start - T_after_rest1;
    heating_dis_C = T_after_dis - T_after_rest1;
    cooling_rest2_C = T_after_dis - T_after_rest2;
    heating_ch_C = T_after_ch - T_after_rest2;
    cooling_rest3_C = T_after_ch - T_end;

    % Elmeleti cella homersekleti idoallando
    tau_s = R_TH_cell_K_per_W * C_TH_cell_J_per_K;
    tau_h = tau_s / 3600;

    % Nyugalmi hulesbol durva becsles:
    % T(t)-Tamb = (T0-Tamb)*exp(-t/tau)
    deltaT0 = T_cell_C(idx_rest1(1)) - T_amb_C(idx_rest1(1));
    deltaT1 = T_cell_C(idx_rest1(end)) - T_amb_C(idx_rest1(end));

    if deltaT0 > 1e-9 && deltaT1 > 1e-9 && deltaT1 < deltaT0
        tau_est_h = -t_rest1_h / log(deltaT1 / deltaT0);
    else
        tau_est_h = NaN;
    end

    % ---------------------------------------------------------------------
    % 9) Eredmeny struktura
    % ---------------------------------------------------------------------
    thermalTest = struct();

    thermalTest.config.E_BESS_kWh = E_BESS_kWh;
    thermalTest.config.P_BESS_kW = P_BESS_kW;
    thermalTest.config.dt_h = dt_h;

    thermalTest.pack.Ns = Ns;
    thermalTest.pack.Np = Np;
    thermalTest.pack.nCells = nCells;
    thermalTest.pack.E_installed_kWh = pack_init_out.E_installed_kWh;
    thermalTest.pack.V_nominal_pack = pack_init_out.V_nominal_pack;

    thermalTest.thermal.M_CELL_kg = M_CELL_kg;
    thermalTest.thermal.CP_J_per_kgK = CP_J_per_kgK;
    thermalTest.thermal.C_TH_cell_J_per_K = C_TH_cell_J_per_K;
    thermalTest.thermal.R_TH_cell_K_per_W = R_TH_cell_K_per_W;
    thermalTest.thermal.tau_h_theoretical = tau_h;
    thermalTest.thermal.tau_h_estimated_from_rest = tau_est_h;

    thermalTest.time_h = time_h;
    thermalTest.P_pack_req_kW = P_pack_req_W / 1000;
    thermalTest.T_amb_C = T_amb_C;
    thermalTest.T_cell_C = T_cell_C;
    thermalTest.SOC = SOC;

    thermalTest.P_loss_joule_pack_kW = P_loss_joule_pack_kW;
    thermalTest.P_loss_total_pack_kW = P_loss_total_pack_kW;
    thermalTest.P_loss_joule_cell_W = P_loss_joule_cell_W;

    thermalTest.q_conv_cell_W = q_conv_cell_W;
    thermalTest.q_conv_pack_kW = q_conv_pack_kW;

    thermalTest.summary.T_start_C = T_start;
    thermalTest.summary.T_after_rest1_C = T_after_rest1;
    thermalTest.summary.T_after_discharge_C = T_after_dis;
    thermalTest.summary.T_after_rest2_C = T_after_rest2;
    thermalTest.summary.T_after_charge_C = T_after_ch;
    thermalTest.summary.T_end_C = T_end;

    thermalTest.summary.cooling_rest1_C = cooling_rest1_C;
    thermalTest.summary.heating_discharge_C = heating_dis_C;
    thermalTest.summary.cooling_rest2_C = cooling_rest2_C;
    thermalTest.summary.heating_charge_C = heating_ch_C;
    thermalTest.summary.cooling_rest3_C = cooling_rest3_C;

    thermalTest.summary.max_T_cell_C = max(T_cell_C);
    thermalTest.summary.min_T_cell_C = min(T_cell_C);
    thermalTest.summary.final_SOC = pack_state_end.cell_state.SOC;
    thermalTest.summary.final_SOH = pack_state_end.cell_state.Deg.SOH;

    thermalTest.checks.rest1_cools_down = cooling_rest1_C > 0;
    thermalTest.checks.discharge_heats_up = heating_dis_C > 0;
    thermalTest.checks.rest2_cools_down = cooling_rest2_C > 0;
    thermalTest.checks.charge_heats_up = heating_ch_C > 0;
    thermalTest.checks.rest3_cools_down = cooling_rest3_C > 0;

    % ---------------------------------------------------------------------
    % 10) Kiiras
    % ---------------------------------------------------------------------
    fprintf('Thermal test summary:\n');
    fprintf('  T start              = %.2f C\n', T_start);
    fprintf('  T after rest 1       = %.2f C\n', T_after_rest1);
    fprintf('  T after discharge    = %.2f C\n', T_after_dis);
    fprintf('  T after rest 2       = %.2f C\n', T_after_rest2);
    fprintf('  T after charge       = %.2f C\n', T_after_ch);
    fprintf('  T end                = %.2f C\n', T_end);
    fprintf('  Max T_cell           = %.2f C\n', max(T_cell_C));
    fprintf('  Theoretical tau      = %.2f h\n', tau_h);
    fprintf('  Estimated tau        = %.2f h\n', tau_est_h);
    fprintf('\n');

    fprintf('Checks:\n');
    fprintf('  Rest 1 cooling       = %d\n', thermalTest.checks.rest1_cools_down);
    fprintf('  Discharge heating    = %d\n', thermalTest.checks.discharge_heats_up);
    fprintf('  Rest 2 cooling       = %d\n', thermalTest.checks.rest2_cools_down);
    fprintf('  Charge heating       = %d\n', thermalTest.checks.charge_heats_up);
    fprintf('  Rest 3 cooling       = %d\n', thermalTest.checks.rest3_cools_down);
    fprintf('\n');

    % ---------------------------------------------------------------------
    % 11) Abrak
    % ---------------------------------------------------------------------
    figure('Name', 'BESS thermal behavior test', ...
        'Position', [100, 100, 1200, 850]);

    subplot(4,1,1);
    hold on; grid on;
    plot(time_h, P_pack_req_W / 1000, 'LineWidth', 1.4);
    ylabel('P_{pack,req} [kW]');
    title('BESS requested power');
    xlim([time_h(1), time_h(end)]);

    subplot(4,1,2);
    hold on; grid on;
    plot(time_h, T_cell_C, 'LineWidth', 1.6);
    plot(time_h, T_amb_C, '--', 'LineWidth', 1.2);
    ylabel('Temperature [C]');
    title('Cell temperature and ambient temperature');
    legend('T cell', 'T ambient', 'Location', 'best');
    xlim([time_h(1), time_h(end)]);

    subplot(4,1,3);
    hold on; grid on;
    plot(time_h, P_loss_joule_pack_kW, 'LineWidth', 1.4);
    plot(time_h, q_conv_pack_kW, 'LineWidth', 1.4);
    ylabel('Power [kW]');
    title('Pack heat generation and heat rejection estimate');
    legend('Joule loss pack', 'Heat rejection pack', 'Location', 'best');
    xlim([time_h(1), time_h(end)]);

    subplot(4,1,4);
    hold on; grid on;
    plot(time_h, SOC * 100, 'LineWidth', 1.4);
    ylabel('SOC [%]');
    xlabel('Time [h]');
    title('Battery SOC');
    xlim([time_h(1), time_h(end)]);

    fprintf('BESS thermal behavior test finished.\n');
end
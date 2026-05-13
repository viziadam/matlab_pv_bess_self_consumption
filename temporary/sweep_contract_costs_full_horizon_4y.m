function sweep_result = sweep_contract_costs_full_horizon_4y()
% SWEEP_CONTRACT_COSTS_FULL_HORIZON_4Y
% Teljes horizontos contract sweep 400:100:1200 kW között.
%
% Cél:
%   Ellenőrizni, hogy a contract-kereső algoritmus által talált optimum
%   összhangban van-e a teljes 4 éves (vagy teljes elérhető) horizonton
%   végzett részletes költségszámítással.
%
% Külső függőségek:
%   build_pv_cache
%   build_load_price_cache
%   create_hungarian_mv_tariff_structure
%   ems_day_ahead_planner_milp_contract
%   ems_realtime_decision_dc
%   bess_pack_model
%   topology_dc_coupled

    clc;
    close all;

    fprintf('=====================================================\n');
    fprintf('TELJES HORIZONTOS CONTRACT SWEEP (400:100:1200 kW)\n');
    fprintf('=====================================================\n');

    % ------------------------------------------------------------------
    % 1) ADATOK BETÖLTÉSE
    % ------------------------------------------------------------------
    fprintf('\nAdatok betöltése...\n');
    PV_A = build_pv_cache(11, [95, 275], [274, 274], 0.325);
    PV_B = build_pv_cache(11, [70, 250], [100.5, 100.5], 0.325);
    [Load, Price] = build_load_price_cache();
    tariff = create_hungarian_mv_tariff_structure();

    nDaysAvailable = min([numel(PV_A), numel(PV_B), numel(Load), numel(Price)]) - 1;

    START_DAY = 1;
    FINAL_DAY = nDaysAvailable;
    nSimDays = FINAL_DAY - START_DAY + 1;

    fprintf('Vizsgált időszak: %d - %d nap\n', START_DAY, FINAL_DAY);
    fprintf('Összes nap: %d\n', nSimDays);

    % ------------------------------------------------------------------
    % 2) BESS PARAMÉTEREK
    % ------------------------------------------------------------------
    E_bess_cap = 1500; % [kWh]
    P_bess_max = 750;  % [kW]

    pars = base_battery_pars_nonideal_(E_bess_cap, P_bess_max);
    pars.P_inv_limit_ac = 550;
    pars.degradation_cost_per_kWh = 5.0;

    fprintf('BESS: E = %.1f kWh | P = %.1f kW\n', E_bess_cap, P_bess_max);

    % ------------------------------------------------------------------
    % 3) CONTRACT RÁCS
    % ------------------------------------------------------------------
    contract_grid = 400:100:1200;
    nC = numel(contract_grid);

    results = repmat(local_make_empty_result_row(), 1, nC);

    % ------------------------------------------------------------------
    % 4) SWEEP
    % ------------------------------------------------------------------
    fprintf('\n--- CONTRACT SWEEP INDUL ---\n');

    for i = 1:nC
        contract_kW = contract_grid(i);

        fprintf('\n====================================\n');
        fprintf('Contract futtatása: %.0f kW\n', contract_kW);
        fprintf('====================================\n');

        t0 = tic;
        res_i = local_run_full_horizon_for_fixed_contract( ...
            START_DAY, FINAL_DAY, PV_A, PV_B, Load, Price, ...
            pars, tariff, contract_kW);
        res_i.runtime_s = toc(t0);

        results(i) = res_i;

        fprintf('Futásidő: %.2f s\n', res_i.runtime_s);
        fprintf('Teljes költség (bázisdíj nélkül): %.2f HUF\n', res_i.total_cost_without_base_huf);
        fprintf('Teljes költség (bázisdíjjal):     %.2f HUF\n', res_i.total_cost_with_base_huf);
        fprintf('Energia költség:                  %.2f HUF\n', res_i.energy_cost_huf);
        fprintf('Degradáció:                       %.2f HUF\n', res_i.degradation_cost_huf);
        fprintf('Overrun költség:                  %.2f HUF\n', res_i.overrun_cost_huf);
        fprintf('Lekötött telj. díj:               %.2f HUF\n', res_i.contracted_power_fee_huf);
        fprintf('Alapdíj:                          %.2f HUF\n', res_i.base_fee_huf);
        fprintf('Max havi peak:                    %.2f kW\n', max(res_i.monthly_peak_kW));
        fprintf('Átlagos havi peak:                %.2f kW\n', mean(res_i.monthly_peak_kW));
    end

    % ------------------------------------------------------------------
    % 5) EREDMÉNYVEKTOROK
    % ------------------------------------------------------------------
    total_without_base = [results.total_cost_without_base_huf];
    total_with_base    = [results.total_cost_with_base_huf];
    energy_cost        = [results.energy_cost_huf];
    degradation_cost   = [results.degradation_cost_huf];
    overrun_cost       = [results.overrun_cost_huf];
    contracted_fee     = [results.contracted_power_fee_huf];
    base_fee           = [results.base_fee_huf];
    runtime_s          = [results.runtime_s];

    max_monthly_peak   = arrayfun(@(r) max(r.monthly_peak_kW), results);
    mean_monthly_peak  = arrayfun(@(r) mean(r.monthly_peak_kW), results);
    p95_monthly_peak   = arrayfun(@(r) prctile(r.monthly_peak_kW, 95), results);

    [~, idx_best_wo_base] = min(total_without_base);
    [~, idx_best_w_base]  = min(total_with_base);

    fprintf('\n=====================================================\n');
    fprintf('SWEEP ÖSSZEFOGLALÓ\n');
    fprintf('=====================================================\n');
    fprintf('Legjobb contract (bázisdíj nélkül): %.0f kW\n', contract_grid(idx_best_wo_base));
    fprintf('Min total cost (bázisdíj nélkül):   %.2f HUF\n', total_without_base(idx_best_wo_base));
    fprintf('Legjobb contract (bázisdíjjal):     %.0f kW\n', contract_grid(idx_best_w_base));
    fprintf('Min total cost (bázisdíjjal):       %.2f HUF\n', total_with_base(idx_best_w_base));

    % ------------------------------------------------------------------
    % 6) PLOTOK
    % ------------------------------------------------------------------

    % 6.1 Teljes költség
    figure('Name', 'Contract sweep - teljes költség', 'Position', [80 80 1200 700]);
    hold on; grid on;
    plot(contract_grid, total_without_base, 'k-o', 'LineWidth', 2, ...
        'DisplayName', 'Teljes költség (bázisdíj nélkül)');
    plot(contract_grid, total_with_base, 'b-s', 'LineWidth', 1.8, ...
        'DisplayName', 'Teljes költség (bázisdíjjal)');
    xline(contract_grid(idx_best_wo_base), 'r--', 'LineWidth', 1.5, ...
        'DisplayName', sprintf('Minimum (no base) = %.0f kW', contract_grid(idx_best_wo_base)));
    xlabel('Lekötött teljesítmény [kW]');
    ylabel('Költség [HUF]');
    title('Teljes költség a contract függvényében');
    legend('Location', 'best');

    % 6.2 Költségkomponensek
    figure('Name', 'Contract sweep - költségkomponensek', 'Position', [100 100 1200 800]);
    tiledlayout(2,2);

    nexttile; hold on; grid on;
    plot(contract_grid, energy_cost, 'k-o', 'LineWidth', 1.8);
    xlabel('Lekötött teljesítmény [kW]');
    ylabel('Költség [HUF]');
    title('Energia költség');

    nexttile; hold on; grid on;
    plot(contract_grid, degradation_cost, 'b-o', 'LineWidth', 1.8);
    xlabel('Lekötött teljesítmény [kW]');
    ylabel('Költség [HUF]');
    title('Degradációs költség');

    nexttile; hold on; grid on;
    plot(contract_grid, overrun_cost, 'r-o', 'LineWidth', 1.8);
    xlabel('Lekötött teljesítmény [kW]');
    ylabel('Költség [HUF]');
    title('Overrun költség');

    nexttile; hold on; grid on;
    plot(contract_grid, contracted_fee, 'm-o', 'LineWidth', 1.8, 'DisplayName', 'Lekötött teljesítménydíj');
    plot(contract_grid, base_fee, 'c--', 'LineWidth', 1.5, 'DisplayName', 'Alapdíj');
    xlabel('Lekötött teljesítmény [kW]');
    ylabel('Költség [HUF]');
    title('Fix díjak');
    legend('Location', 'best');

    % 6.3 Peak statisztikák
    figure('Name', 'Contract sweep - havi peak statisztikák', 'Position', [120 120 1200 700]);
    hold on; grid on;
    plot(contract_grid, max_monthly_peak, 'k-o', 'LineWidth', 1.8, 'DisplayName', 'Max havi peak');
    plot(contract_grid, p95_monthly_peak, 'b-s', 'LineWidth', 1.8, 'DisplayName', '95% havi peak');
    plot(contract_grid, mean_monthly_peak, 'm-d', 'LineWidth', 1.8, 'DisplayName', 'Átlagos havi peak');
    plot(contract_grid, contract_grid, 'r--', 'LineWidth', 1.5, 'DisplayName', 'y = contract');
    xlabel('Lekötött teljesítmény [kW]');
    ylabel('Peak [kW]');
    title('Havi peak statisztikák a contract függvényében');
    legend('Location', 'best');

    % 6.4 Futásidő
    figure('Name', 'Contract sweep - futásidő', 'Position', [140 140 1000 500]);
    hold on; grid on;
    bar(contract_grid, runtime_s, 'FaceColor', [0.2 0.6 0.8]);
    xlabel('Lekötött teljesítmény [kW]');
    ylabel('Futásidő [s]');
    title('Futásidő contractonként');

    % ------------------------------------------------------------------
    % 7) KIMENET
    % ------------------------------------------------------------------
    sweep_result = struct();
    sweep_result.contract_grid = contract_grid;
    sweep_result.results = results;
    sweep_result.best_contract_without_base = contract_grid(idx_best_wo_base);
    sweep_result.best_contract_with_base = contract_grid(idx_best_w_base);
end


% =========================================================================
% SEGÉDFÜGGVÉNYEK
% =========================================================================

function res = local_run_full_horizon_for_fixed_contract( ...
    START_DAY, FINAL_DAY, PV_A, PV_B, Load, Price, pars_in, tariff_in, contract_kW)

    pars = pars_in;
    tariff = tariff_in;

    init_params = struct( ...
        'target_energy_kWh', pars.E_cap_nom, ...
        'max_power_W', pars.P_rated * 1000, ...
        'initial_soc', 0.5);

    [pack_info, state_bess] = bess_pack_model(0, 'init', init_params, 1/12, []);
    pars.E_cap_nom = pack_info.E_installed_kWh;

    nSimDays = FINAL_DAY - START_DAY + 1;
    month_ids = zeros(1, nSimDays);

    daily_energy_cost   = zeros(1, nSimDays);
    daily_deg_cost      = zeros(1, nSimDays);
    daily_overrun_cost  = zeros(1, nSimDays);
    daily_peak_with_bess = zeros(1, nSimDays);
    daily_peak_no_bess   = zeros(1, nSimDays);

    monthly_peak_map = containers.Map('KeyType', 'double', 'ValueType', 'double');
    current_month_id = [];
    current_month_peak = 0;

    for d = START_DAY:FINAL_DAY
        ii = d - START_DAY + 1;

        dt_h = PV_A(d).dt_h;

        % Tényleges napi profilok
        P_pv_dc_actual = (PV_A(d).Ppv + PV_B(d).Ppv) / 1000;
        P_load_actual  = Load(d).P_load_kW;
        Prices_today   = Price(d);

        % 48 órás forecast
        P_load_f_today = Load(d).P_load_kW;
        P_pv_f_today   = (PV_A(d).Ppv + PV_B(d).Ppv) / 1000;

        P_load_f_tomorrow = Load(d+1).P_load_kW;
        P_pv_f_tomorrow   = (PV_A(d+1).Ppv + PV_B(d+1).Ppv) / 1000;
        Prices_tomorrow   = Price(d+1);

        P_load_48h = [P_load_f_today, P_load_f_tomorrow];
        P_pv_48h   = [P_pv_f_today,   P_pv_f_tomorrow];

        Prices_48h = struct();
        Prices_48h.buy_huf = [Prices_today.buy_huf, Prices_tomorrow.buy_huf];

        month_id = floor((d - 1) / 30) + 1;
        month_ids(ii) = month_id;

        if isempty(current_month_id) || month_id ~= current_month_id
            current_month_id = month_id;
            current_month_peak = 0;
        end

        contract_state = struct();
        contract_state.P_contract_kW = contract_kW;
        contract_state.P_month_max_so_far_kW = current_month_peak;
        contract_state.current_day_of_month = mod(d - 1, 30) + 1;

        pars.SoC_initial = state_bess.cell_state.SOC;

        plan_full = ems_day_ahead_planner_milp_contract( ...
            P_load_48h, P_pv_48h, Prices_48h, pars, tariff, dt_h, contract_state);

        nDay = length(P_load_actual);

        plan_today = plan_full;
        plan_today.trade_buy_mask  = plan_full.trade_buy_mask(1:nDay);
        plan_today.trade_sell_mask = plan_full.trade_sell_mask(1:nDay);
        plan_today.P_ch_plan       = plan_full.P_ch_plan(1:nDay);
        plan_today.P_dis_plan      = plan_full.P_dis_plan(1:nDay);
        plan_today.P_grid_plan     = plan_full.P_grid_plan(1:nDay);
        plan_today.P_curt_plan     = plan_full.P_curt_plan(1:nDay);
        plan_today.SoC_plan        = plan_full.SoC_plan(1:nDay);

        P_bess_dc_req_kW = ems_realtime_decision_dc( ...
            P_pv_dc_actual, P_load_actual, plan_today, pars);

        [dayRes, state_bess] = topology_dc_coupled( ...
            P_bess_dc_req_kW, P_pv_dc_actual, P_load_actual, ...
            Prices_today, pars, state_bess, dt_h);

        actual_grid = dayRes.E_grid_import(:) / dt_h;
        actual_peak = max(actual_grid);

        prev_overrun = max(0, current_month_peak - contract_kW);
        current_month_peak = max(current_month_peak, actual_peak);
        new_overrun = max(0, current_month_peak - contract_kW);

        monthly_overrun_cost_per_kW = tariff.penalty_rate_huf_per_kW_year / 12;
        overrun_increment_cost_actual = monthly_overrun_cost_per_kW * (new_overrun - prev_overrun);

        buy_today = Prices_today.buy_huf(:);
        buy_total = buy_today + tariff.distribution_energy_rate_huf_per_kWh + ...
                               tariff.transmission_energy_rate_huf_per_kWh;

        energy_cost_actual = sum(buy_total(:) .* actual_grid(:)) * dt_h;
        deg_cost_actual = pars.degradation_cost_per_kWh * ...
                          sum(dayRes.E_stored(:) + dayRes.E_discharged(:));

        P_grid_no_bess = max(P_load_actual(:) - P_pv_dc_actual(:) * pars.inv_eta, 0);

        daily_energy_cost(ii)    = energy_cost_actual;
        daily_deg_cost(ii)       = deg_cost_actual;
        daily_overrun_cost(ii)   = overrun_increment_cost_actual;
        daily_peak_with_bess(ii) = actual_peak;
        daily_peak_no_bess(ii)   = max(P_grid_no_bess);

        monthly_peak_map(month_id) = current_month_peak;
    end

    unique_months = unique(month_ids);
    monthly_peak_kW = zeros(1, numel(unique_months));

    for k = 1:numel(unique_months)
        monthly_peak_kW(k) = monthly_peak_map(unique_months(k));
    end

    total_days = nSimDays;
    total_energy_cost = sum(daily_energy_cost);
    total_deg_cost = sum(daily_deg_cost);
    total_overrun_cost = sum(daily_overrun_cost);

    contracted_power_fee = (total_days / tariff.days_in_year) * ...
        (contract_kW * tariff.annual_contracted_power_fee_huf_per_kW);

    base_fee = (total_days / tariff.days_in_year) * tariff.annual_base_fee_huf;

    res = struct();
    res.contract_kW = contract_kW;
    res.energy_cost_huf = total_energy_cost;
    res.degradation_cost_huf = total_deg_cost;
    res.overrun_cost_huf = total_overrun_cost;
    res.contracted_power_fee_huf = contracted_power_fee;
    res.base_fee_huf = base_fee;
    res.total_cost_without_base_huf = total_energy_cost + total_deg_cost + total_overrun_cost + contracted_power_fee;
    res.total_cost_with_base_huf    = res.total_cost_without_base_huf + base_fee;
    res.monthly_peak_kW = monthly_peak_kW;
    res.daily_peak_with_bess = daily_peak_with_bess;
    res.daily_peak_no_bess   = daily_peak_no_bess;
    res.runtime_s = NaN;
end


function row = local_make_empty_result_row()
    row = struct( ...
        'contract_kW', NaN, ...
        'energy_cost_huf', NaN, ...
        'degradation_cost_huf', NaN, ...
        'overrun_cost_huf', NaN, ...
        'contracted_power_fee_huf', NaN, ...
        'base_fee_huf', NaN, ...
        'total_cost_without_base_huf', NaN, ...
        'total_cost_with_base_huf', NaN, ...
        'monthly_peak_kW', [], ...
        'daily_peak_with_bess', [], ...
        'daily_peak_no_bess', [], ...
        'runtime_s', NaN);
end



function run_single_bess_contract_search()
% RUN_SINGLE_BESS_4YEAR_CONTRACT_SEARCH
% Egyetlen BESS méretre lefuttatja a 4 éves contract optimumkeresést
% és az eredmények kiértékelését.
%
% Feltételezett külső függvények ugyanabban a mappában:
%   build_pv_cache
%   build_load_price_cache
%   create_hungarian_mv_tariff_structure
%   search_optimal_contract_capacity
%   ems_day_ahead_planner_milp_contract
%   ems_realtime_decision_dc
%   bess_pack_model
%   topology_dc_coupled
%   local_zscore
%   local_kmeans_basic
%   analyze_daily_peak_distribution
%
% Megjegyzés:
%   Ez a függvény a teljes rendelkezésre álló idősoron fut.
%   A 4 év itt úgy értendő, hogy a cache-ben elérhető teljes adathalmazt használjuk.
%   Ha a cache pontosan 4 évet tartalmaz, akkor azon fut végig.
%678709578.01 HUF
    clc; close all;
    fprintf('=== 4 ÉVES SINGLE-BESS CONTRACT OPTIMUMKERESÉS ===\n');

    % =====================================================================
    % 1) ADATOK BETÖLTÉSE
    % =====================================================================
    fprintf('Adatok betöltése...\n');

    PV_A = build_pv_cache(11, [95, 275], [274, 274], 0.325);
    PV_B = build_pv_cache(11, [70, 250], [100.5, 100.5], 0.325);
    [Load, Price] = build_load_price_cache();

    % A teljes rendelkezésre álló, közös hosszt használjuk.
    % Kell 1 nap look-ahead is, ezért a max napindexből levonunk 1-et.
    nDaysAvailable = min([numel(PV_A), numel(PV_B), numel(Load), numel(Price)]) - 1;

    START_DAY = 1;
    FINAL_DAY = nDaysAvailable;
    nSimDays = FINAL_DAY - START_DAY + 1;

    fprintf('Elérhető teljes időszak: %d nap\n', nSimDays);

    % =====================================================================
    % 2) BESS PARAMÉTEREK
    % =====================================================================
    E_bess_cap = 3000;   % [kWh]
    P_bess_max = 1500;    % [kW]

    pars = base_battery_pars_nonideal_(E_bess_cap, P_bess_max);
    pars.P_inv_limit_ac = 550;
    pars.degradation_cost_per_kWh = 5.0;

    fprintf('BESS paraméterek:\n');
    fprintf('  E_bess_cap = %.1f kWh\n', E_bess_cap);
    fprintf('  P_bess_max = %.1f kW\n', P_bess_max);
    fprintf('  P_inv_limit_ac = %.1f kW\n', pars.P_inv_limit_ac);
    fprintf('  degradation_cost_per_kWh = %.2f HUF/kWh\n', pars.degradation_cost_per_kWh);

    % =====================================================================
    % 3) NAPI CACHE ÉPÍTÉSE A TELJES IDŐSZAKRA
    % =====================================================================
    fprintf('\n--- TELJES IDŐSZAK CACHE ÉPÍTÉSE ---\n');
    t_cache = tic;
    day_cache = build_full_day_cache_4y(START_DAY, FINAL_DAY, PV_A, PV_B, Load, Price, pars.inv_eta);
    t_cache_done = toc(t_cache);
    fprintf('Cache elkészült: %.2f s\n', t_cache_done);

    % =====================================================================
    % 4) FEATURE-K, PROXY ÉS VALIDÁCIÓS HALMAZOK
    % =====================================================================
    fprintf('\n--- FEATURE-K ÉS REPREZENTÁNS NAPOK ---\n');

    features = build_daily_features_4y(day_cache);

    % 7 napos súlyozott proxy
    rep_cfg_proxy.n_typical = 5;
    rep_cfg_proxy.n_extreme = 2;
    rep_set_proxy = local_select_representative_days_pattern_based(features, day_cache, rep_cfg_proxy);

    % 20 napos validációs halmaz
    rep_cfg_valid.n_clusters = 5;
    rep_cfg_valid.n_validation_days_total = 20;
    rep_cfg_valid.n_extreme_force = 4;
    rep_set_valid = local_select_validation_days_pattern_based(features, day_cache, rep_cfg_valid);

    fprintf('Proxy napok száma: %d\n', numel(rep_set_proxy.all_day_indices));
    fprintf('Validációs napok száma: %d\n', numel(rep_set_valid.validation_day_indices));

    % =====================================================================
    % 5) TARIFFA
    % =====================================================================
    tariff = create_hungarian_mv_tariff_structure();

    % =====================================================================
    % 6) KÜLSŐ CONTRACT KERESÉS
    % =====================================================================
    fprintf('\n--- CONTRACT OPTIMUMKERESÉS ---\n');

    search_cfg = struct();
    search_cfg.coarse_step_kW = 25;
    search_cfg.fine_step_kW = 10;
    search_cfg.validation_offsets_kW = [-20 -10 0 10 20];

    t_search = tic;
    search_result = search_optimal_contract_capacity( ...
        day_cache, rep_set_proxy, rep_set_valid, pars, tariff, search_cfg);
    t_search_done = toc(t_search);

    best_contract = search_result.best_contract_kW;
    best_detail = search_result.best_validation_result;

    fprintf('\n=== KERESÉS KÉSZ ===\n');
    fprintf('Optimális lekötött teljesítmény: %.1f kW\n', best_contract);
    fprintf('Contract keresés futásideje: %.2f s\n', t_search_done);

    % =====================================================================
    % 7) TELJES 4 ÉVES FUTTATÁS A LEGJOBB CONTRACTTAL
    % =====================================================================
    fprintf('\n--- TELJES 4 ÉVES FUTTATÁS AZ OPTIMÁLIS CONTRACTTAL ---\n');
    t_full = tic;
    % full_result = run_full_horizon_for_fixed_contract(day_cache, pars, tariff, best_contract, true);

    % Jellegzetes napok részletes mentése:
    % - validációs reprezentáns napok
    % - kényszerített szélsőséges napok
    % - plusz a teljes futás közben automatikusan eltároljuk a legnagyobb
    %   túllépéses napokat is
    detail_cfg = struct();
    detail_cfg.day_indices = unique([ ...
        rep_set_valid.extreme_day_indices(:); ...
        rep_set_valid.validation_day_indices(:)], 'stable');

    detail_cfg.max_representative_plots = 8;
    detail_cfg.max_overrun_days = 8;
    detail_cfg.overrun_tolerance_kW = 1e-6;

    full_result = run_full_horizon_for_fixed_contract( ...
        day_cache, pars, tariff, best_contract, true, detail_cfg);

    t_full_done = toc(t_full);

    fprintf('Teljes 4 éves futás kész: %.2f s\n', t_full_done);

    % =====================================================================
    % 8) LOGOS KIÉRTÉKELÉS
    % =====================================================================
    fprintf('\n================ VÉGSŐ ÖSSZEFOGLALÓ ================\n');
    fprintf('Időszak hossza:                         %d nap\n', nSimDays);
    fprintf('Optimális contract:                     %.2f kW\n', best_contract);

    fprintf('\nKöltségek a teljes időszakra:\n');
    fprintf('  Energia költség:                      %.2f HUF\n', full_result.energy_cost_period_huf);
    fprintf('  Degradációs költség:                  %.2f HUF\n', full_result.degradation_cost_period_huf);
    fprintf('  Overrun költség:                      %.2f HUF\n', full_result.overrun_cost_period_huf);
    fprintf('  Fix contract költség:                 %.2f HUF\n', full_result.contract_cost_period_huf);
    fprintf('  Teljes költség:                       %.2f HUF\n', full_result.total_cost_period_huf);

    fprintf('\nPeak statisztikák:\n');
    fprintf('  No-BESS max napi peak:                %.2f kW\n', max(full_result.daily_peak_no_bess));
    fprintf('  BESS max napi peak:                   %.2f kW\n', max(full_result.daily_peak_with_bess));
    fprintf('  BESS átlagos napi peak:               %.2f kW\n', mean(full_result.daily_peak_with_bess));
    fprintf('  BESS 95%% napi peak:                   %.2f kW\n', prctile(full_result.daily_peak_with_bess, 95));
    fprintf('  MILP átlagos havi-peak jelölt:        %.2f kW\n', mean(full_result.daily_planned_peak));
    fprintf('  Átlagos napi BESS throughput:         %.2f kWh/nap\n', mean(full_result.daily_bess_throughput));

    fprintf('\nFutásidők:\n');
    fprintf('  Cache építés:                         %.2f s\n', t_cache_done);
    fprintf('  Contract keresés:                     %.2f s\n', t_search_done);
    fprintf('  Teljes 4 éves futás:                  %.2f s\n', t_full_done);
    fprintf('  Összesen:                             %.2f s\n', t_cache_done + t_search_done + t_full_done);

    % =====================================================================
    % 9) ÁBRÁK
    % =====================================================================
    plot_contract_search_summary_4y(search_result);
    plot_full_horizon_summary_4y(full_result, best_contract);

    % Eredeti utolsó nap részletes nézete
    plot_final_day_detail_4y(full_result, pars);

    % Diagnosztikai részletes ábrák:
    % - legnagyobb túllépéses napok
    % - néhány reprezentáns / jellegzetes nap
    plot_selected_day_details_4y(full_result, pars);

    fprintf('\n=== KÉSZ ===\n');
end


% =========================================================================
% TELJES IDŐSZAK CACHE
% =========================================================================
function day_cache = build_full_day_cache_4y(START_DAY, FINAL_DAY, PV_A, PV_B, Load, Price, inv_eta)

    nSimDays = FINAL_DAY - START_DAY + 1;
    day_cache = repmat(struct(), 1, nSimDays);

    for d = START_DAY:FINAL_DAY
        ii = d - START_DAY + 1;

        dt_h = PV_A(d).dt_h;

        P_pv_dc_actual = (PV_A(d).Ppv + PV_B(d).Ppv) / 1000;
        P_load_actual  = Load(d).P_load_kW;
        Prices_today   = Price(d);

        P_load_f_today = Load(d).P_load_kW;
        P_pv_f_today   = (PV_A(d).Ppv + PV_B(d).Ppv) / 1000;

        P_load_f_tomorrow = Load(d+1).P_load_kW;
        P_pv_f_tomorrow   = (PV_A(d+1).Ppv + PV_B(d+1).Ppv) / 1000;
        Prices_tomorrow   = Price(d+1);

        P_load_48h = [P_load_f_today, P_load_f_tomorrow];
        P_pv_48h   = [P_pv_f_today,   P_pv_f_tomorrow];

        Prices_48h = struct();
        Prices_48h.buy_huf = [Prices_today.buy_huf, Prices_tomorrow.buy_huf];

        P_grid_no_bess_day = max(P_load_actual - P_pv_dc_actual * inv_eta, 0);

        day_cache(ii).abs_day = d;
        day_cache(ii).dt_h = dt_h;

        day_cache(ii).P_pv_dc_actual = P_pv_dc_actual;
        day_cache(ii).P_load_actual  = P_load_actual;
        day_cache(ii).Prices_today   = Prices_today;

        day_cache(ii).P_load_48h = P_load_48h;
        day_cache(ii).P_pv_48h   = P_pv_48h;
        day_cache(ii).Prices_48h = Prices_48h;

        day_cache(ii).P_grid_no_bess_day = P_grid_no_bess_day;
        day_cache(ii).no_bess_peak = max(P_grid_no_bess_day);
    end
end


% =========================================================================
% FEATURE-K
% =========================================================================
function features = build_daily_features_4y(day_cache)

    nDays = numel(day_cache);
    X = zeros(nDays, 10);

    for i = 1:nDays
        dc = day_cache(i);

        P_load = dc.P_load_actual(:);
        P_pv   = dc.P_pv_dc_actual(:) * 0.97;
        P_grid = dc.P_grid_no_bess_day(:);
        p_buy  = dc.Prices_today.buy_huf(:);

        N = numel(P_load);
        time_h = (0:N-1)' * dc.dt_h;

        evening_mask = time_h >= 16 & time_h < 22;
        morning_mask = time_h >= 6 & time_h < 10;

        load_energy = sum(P_load) * dc.dt_h;
        load_peak   = max(P_load);
        load_mean   = mean(P_load);

        pv_energy = sum(P_pv) * dc.dt_h;
        pv_peak   = max(P_pv);

        grid_energy = sum(P_grid) * dc.dt_h;
        grid_peak   = max(P_grid);
        evening_grid_peak = max(P_grid(evening_mask));
        morning_grid_peak = max(P_grid(morning_mask));

        price_mean = mean(p_buy);
        price_spread = max(p_buy) - min(p_buy);

        X(i,:) = [ ...
            load_energy, ...
            load_peak, ...
            load_mean, ...
            pv_energy, ...
            pv_peak, ...
            grid_energy, ...
            grid_peak, ...
            evening_grid_peak, ...
            price_mean, ...
            price_spread ];
    end

    features = struct();
    features.raw = X;
    features.z   = local_zscore(X);
end


% =========================================================================
% 7 NAPOS SÚLYOZOTT PROXY HALMAZ
% =========================================================================
function rep_set = local_select_representative_days_pattern_based(features, day_cache, cfg)

    X = features.z;

    n_typical = cfg.n_typical;
    n_extreme = cfg.n_extreme;

    [cluster_id, centers] = local_kmeans_basic(X, n_typical, 50);

    typical_day_indices = zeros(1, n_typical);
    cluster_weights = zeros(1, n_typical);

    for k = 1:n_typical
        idx_k = find(cluster_id == k);
        cluster_weights(k) = numel(idx_k);

        if isempty(idx_k)
            typical_day_indices(k) = 1;
            continue;
        end

        Xk = X(idx_k,:);
        ck = centers(k,:);
        d2 = sum((Xk - ck).^2, 2);
        [~, imin] = min(d2);
        typical_day_indices(k) = idx_k(imin);
    end

    no_bess_peak = arrayfun(@(d) d.no_bess_peak, day_cache);
    [~, idx_sorted_peak] = sort(no_bess_peak, 'descend');

    extreme_day_indices = [];
    for j = 1:numel(idx_sorted_peak)
        cand = idx_sorted_peak(j);
        if ~ismember(cand, typical_day_indices)
            extreme_day_indices(end+1) = cand; %#ok<AGROW>
        end
        if numel(extreme_day_indices) >= n_extreme
            break;
        end
    end

    all_day_indices = [typical_day_indices, extreme_day_indices];

    extreme_weight_each = max(1, round(0.5 * mean(cluster_weights)));

    weights = [cluster_weights, repmat(extreme_weight_each, 1, numel(extreme_day_indices))];
    weights = weights / sum(weights);

    rep_set = struct();
    rep_set.cluster_id = cluster_id;
    rep_set.centers = centers;
    rep_set.typical_day_indices = typical_day_indices;
    rep_set.extreme_day_indices = extreme_day_indices;
    rep_set.all_day_indices = all_day_indices;
    rep_set.weights = weights;
end


% =========================================================================
% 20 NAPOS VALIDÁCIÓS HALMAZ
% =========================================================================
function rep_set = local_select_validation_days_pattern_based(features, day_cache, cfg)

    X = features.z;
    nDays = size(X,1);

    n_clusters = cfg.n_clusters;
    n_total = cfg.n_validation_days_total;
    n_extreme_force = cfg.n_extreme_force;

    [cluster_id, centers] = local_kmeans_basic(X, n_clusters, 50);

    cluster_sizes = zeros(1, n_clusters);
    for k = 1:n_clusters
        cluster_sizes(k) = sum(cluster_id == k);
    end
    cluster_frac = cluster_sizes / sum(cluster_sizes);

    raw_counts = cluster_frac * n_total;
    base_counts = floor(raw_counts);
    remainder = n_total - sum(base_counts);

    frac_part = raw_counts - base_counts;
    [~, idx_frac] = sort(frac_part, 'descend');

    cluster_sample_counts = base_counts;
    for j = 1:remainder
        cluster_sample_counts(idx_frac(j)) = cluster_sample_counts(idx_frac(j)) + 1;
    end

    for k = 1:n_clusters
        if cluster_sizes(k) > 0 && cluster_sample_counts(k) == 0
            cluster_sample_counts(k) = 1;
        end
    end

    while sum(cluster_sample_counts) > n_total
        eligible = find(cluster_sample_counts > 1);
        if isempty(eligible), break; end
        [~, imax] = max(cluster_sample_counts(eligible));
        cluster_sample_counts(eligible(imax)) = cluster_sample_counts(eligible(imax)) - 1;
    end

    no_bess_peak = arrayfun(@(d) d.no_bess_peak, day_cache);
    [~, idx_sorted_peak] = sort(no_bess_peak, 'descend');

    extreme_day_indices = unique(idx_sorted_peak(1:min(n_extreme_force, nDays)));

    validation_days = extreme_day_indices(:).';

    for k = 1:n_clusters
        idx_k = find(cluster_id == k);
        if isempty(idx_k)
            continue;
        end

        need_k = cluster_sample_counts(k);

        already_k = idx_k(ismember(idx_k, validation_days));
        n_already = numel(already_k);
        n_to_add = max(0, need_k - n_already);

        if n_to_add == 0
            continue;
        end

        Xk = X(idx_k,:);
        ck = centers(k,:);
        d2 = sum((Xk - ck).^2, 2);
        [~, order] = sort(d2, 'ascend');
        cand = idx_k(order);

        cand = cand(~ismember(cand, validation_days));
        cand = cand(1:min(n_to_add, numel(cand)));

        validation_days = [validation_days, cand(:).']; %#ok<AGROW>
    end

    if numel(validation_days) < n_total
        remaining = setdiff(1:nDays, validation_days, 'stable');
        n_missing = n_total - numel(validation_days);
        validation_days = [validation_days, remaining(1:min(n_missing, numel(remaining)))];
    end

    if numel(validation_days) > n_total
        [~, ord] = sort(no_bess_peak(validation_days), 'descend');
        validation_days = validation_days(ord);
        validation_days = validation_days(1:n_total);
    end

    validation_days = unique(validation_days, 'stable');

    if numel(validation_days) < n_total
        remaining = setdiff(1:nDays, validation_days, 'stable');
        n_missing = n_total - numel(validation_days);
        validation_days = [validation_days, remaining(1:min(n_missing, numel(remaining)))];
    end

    rep_set = struct();
    rep_set.cluster_id = cluster_id;
    rep_set.centers = centers;
    rep_set.cluster_sizes = cluster_sizes;
    rep_set.cluster_sample_counts = cluster_sample_counts;
    rep_set.extreme_day_indices = extreme_day_indices;
    rep_set.validation_day_indices = sort(validation_days(:).');
end


% =========================================================================
% TELJES FUTTATÁS FIX CONTRACTTAL A TELJES 4 ÉVRE
% =========================================================================
% function result = run_full_horizon_for_fixed_contract(day_cache, pars_in, tariff_in, contract_kW, store_detail)
% 
%     if nargin < 5
%         store_detail = false;
%     end
% 
%     pars = pars_in;
%     tariff = tariff_in;
% 
%     nDays = numel(day_cache);
% 
%     init_params = struct( ...
%         'target_energy_kWh', pars.E_cap_nom, ...
%         'max_power_W', pars.P_rated * 1000, ...
%         'initial_soc', 0.5);
% 
%     [pack_info, state_bess] = bess_pack_model(0, 'init', init_params, 1/12, []);
%     pars.E_cap_nom = pack_info.E_installed_kWh;
% 
%     monthly_overrun_cost_per_kW = tariff.penalty_rate_huf_per_kW_year / 12;
% 
%     current_month_id = [];
%     current_month_peak = 0;
% 
%     daily_peak_no_bess    = zeros(1, nDays);
%     daily_peak_with_bess  = zeros(1, nDays);
%     daily_energy_cost     = zeros(1, nDays);
%     daily_deg_cost        = zeros(1, nDays);
%     daily_overrun_cost    = zeros(1, nDays);
%     daily_total_cost      = zeros(1, nDays);
%     daily_bess_throughput = zeros(1, nDays);
%     daily_planned_peak    = zeros(1, nDays);
%     daily_ref_contract    = contract_kW * ones(1, nDays);
% 
%     plot_plan = [];
%     plot_res = [];
%     plot_load = [];
%     plot_pv = [];
%     plot_price = [];
%     soc_start_of_final_day = NaN;
% 
%     for kk = 1:nDays
%         dc = day_cache(kk);
% 
%         month_id = local_get_month_id_from_abs_day_4y(dc.abs_day);
% 
%         if isempty(current_month_id) || month_id ~= current_month_id
%             current_month_id = month_id;
%             current_month_peak = 0;
%         end
% 
%         if kk == nDays
%             soc_start_of_final_day = state_bess.cell_state.SOC;
%         end
% 
%         contract_state = struct();
%         contract_state.P_contract_kW = contract_kW;
%         contract_state.P_month_max_so_far_kW = current_month_peak;
%         contract_state.current_day_of_month = mod(dc.abs_day - 1, 30) + 1;
% 
%         contract_state.P_grid_hard_cap_kW = 700;
% 
%         pars.SoC_initial = state_bess.cell_state.SOC;
% 
%         plan_full = ems_day_ahead_planner_milp_contract( ...
%             dc.P_load_48h, dc.P_pv_48h, dc.Prices_48h, ...
%             pars, tariff, dc.dt_h, contract_state, 15);
% 
%         nDay = length(dc.P_load_actual);
% 
%         plan_today = plan_full;
%         plan_today.trade_buy_mask  = plan_full.trade_buy_mask(1:nDay);
%         plan_today.trade_sell_mask = plan_full.trade_sell_mask(1:nDay);
%         plan_today.P_ch_plan       = plan_full.P_ch_plan(1:nDay);
%         plan_today.P_dis_plan      = plan_full.P_dis_plan(1:nDay);
%         plan_today.P_grid_plan     = plan_full.P_grid_plan(1:nDay);
%         plan_today.P_curt_plan     = plan_full.P_curt_plan(1:nDay);
%         plan_today.SoC_plan        = plan_full.SoC_plan(1:nDay);
% 
%         P_bess_dc_req_kW = ems_realtime_decision_dc( ...
%             dc.P_pv_dc_actual, dc.P_load_actual, plan_today, pars);
% 
%         [dayRes, state_bess] = topology_dc_coupled( ...
%             P_bess_dc_req_kW, dc.P_pv_dc_actual, dc.P_load_actual, ...
%             dc.Prices_today, pars, state_bess, dc.dt_h);
% 
%         actual_grid = (dayRes.E_grid_import(:)) / dc.dt_h;
%         actual_peak = max(actual_grid);
% 
%         prev_overrun = max(0, current_month_peak - contract_kW);
%         current_month_peak = max(current_month_peak, actual_peak);
%         new_overrun = max(0, current_month_peak - contract_kW);
%         overrun_increment_cost_actual = monthly_overrun_cost_per_kW * (new_overrun - prev_overrun);
% 
%         buy_today = dc.Prices_today.buy_huf(:);
%         buy_total = buy_today + tariff.distribution_energy_rate_huf_per_kWh + ...
%                        tariff.transmission_energy_rate_huf_per_kWh;
% 
%         energy_cost_actual = sum(buy_total(:) .* actual_grid(:)) * dc.dt_h;
%         deg_cost_actual = pars.degradation_cost_per_kWh * ...
%                   sum(dayRes.E_stored(:) + dayRes.E_discharged(:));
% 
%         daily_peak_no_bess(kk)    = dc.no_bess_peak;
%         daily_peak_with_bess(kk)  = actual_peak;
%         daily_energy_cost(kk)     = energy_cost_actual;
%         daily_deg_cost(kk)        = deg_cost_actual;
%         daily_overrun_cost(kk)    = overrun_increment_cost_actual;
%         daily_total_cost(kk)      = energy_cost_actual + deg_cost_actual + overrun_increment_cost_actual;
%         daily_bess_throughput(kk) = sum(dayRes.E_stored + dayRes.E_discharged);
%         daily_planned_peak(kk)    = plan_today.P_month_peak_candidate;
% 
%         if store_detail && kk == nDays
%             plot_plan = plan_today;
%             plot_res = dayRes;
%             plot_load = dc.P_load_actual;
%             plot_pv = dc.P_pv_dc_actual;
%             plot_price = dc.Prices_today;
%         end
%     end
% 
%     contract_cost_period = (nDays / tariff.days_in_year) * ...
%         (tariff.annual_contracted_power_fee_huf_per_kW * contract_kW + tariff.annual_base_fee_huf);
% 
%     result = struct();
%     result.contract_kW = contract_kW;
%     result.energy_cost_period_huf = sum(daily_energy_cost);
%     result.degradation_cost_period_huf = sum(daily_deg_cost);
%     result.overrun_cost_period_huf = sum(daily_overrun_cost);
%     result.contract_cost_period_huf = contract_cost_period;
%     result.total_cost_period_huf = result.energy_cost_period_huf + ...
%                                    result.degradation_cost_period_huf + ...
%                                    result.overrun_cost_period_huf + ...
%                                    result.contract_cost_period_huf;
% 
%     result.daily_peak_no_bess = daily_peak_no_bess;
%     result.daily_peak_with_bess = daily_peak_with_bess;
%     result.daily_energy_cost = daily_energy_cost;
%     result.daily_deg_cost = daily_deg_cost;
%     result.daily_overrun_cost = daily_overrun_cost;
%     result.daily_total_cost = daily_total_cost;
%     result.daily_bess_throughput = daily_bess_throughput;
%     result.daily_planned_peak = daily_planned_peak;
%     result.daily_ref_contract = daily_ref_contract;
%     result.days_axis = [day_cache.abs_day];
% 
%     result.final_day = struct();
%     result.final_day.plan = plot_plan;
%     result.final_day.res = plot_res;
%     result.final_day.load = plot_load;
%     result.final_day.pv = plot_pv;
%     result.final_day.price = plot_price;
%     result.final_day.soc_start = soc_start_of_final_day;
% end

function result = run_full_horizon_for_fixed_contract(day_cache, pars_in, tariff_in, contract_kW, store_detail, detail_cfg)

    if nargin < 5
        store_detail = false;
    end

    if nargin < 6 || isempty(detail_cfg)
        detail_cfg = struct();
    end

    if ~isfield(detail_cfg, 'day_indices')
        detail_cfg.day_indices = [];
    end

    if ~isfield(detail_cfg, 'max_representative_plots')
        detail_cfg.max_representative_plots = 8;
    end

    if ~isfield(detail_cfg, 'max_overrun_days')
        detail_cfg.max_overrun_days = 8;
    end

    if ~isfield(detail_cfg, 'overrun_tolerance_kW')
        detail_cfg.overrun_tolerance_kW = 1e-6;
    end

    pars = pars_in;
    tariff = tariff_in;

    nDays = numel(day_cache);

    detail_day_indices = unique(detail_cfg.day_indices(:).');
    detail_day_indices = detail_day_indices(detail_day_indices >= 1 & detail_day_indices <= nDays);

    init_params = struct( ...
        'target_energy_kWh', pars.E_cap_nom, ...
        'max_power_W', pars.P_rated * 1000, ...
        'initial_soc', 0.5);

    [pack_info, state_bess] = bess_pack_model(0, 'init', init_params, 1/12, []);
    pars.E_cap_nom = pack_info.E_installed_kWh;

    monthly_overrun_cost_per_kW = tariff.penalty_rate_huf_per_kW_year / 12;

    current_month_id = [];
    current_month_peak = 0;

    daily_peak_no_bess    = zeros(1, nDays);
    daily_peak_with_bess  = zeros(1, nDays);
    daily_energy_cost     = zeros(1, nDays);
    daily_deg_cost        = zeros(1, nDays);
    daily_overrun_cost    = zeros(1, nDays);
    daily_total_cost      = zeros(1, nDays);
    daily_bess_throughput = zeros(1, nDays);
    daily_planned_peak    = zeros(1, nDays);
    daily_ref_contract    = contract_kW * ones(1, nDays);

    plot_plan = [];
    plot_res = [];
    plot_load = [];
    plot_pv = [];
    plot_price = [];
    soc_start_of_final_day = NaN;

    detail_days = struct( ...
        'day_index', {}, ...
        'abs_day', {}, ...
        'type', {}, ...
        'overrun_margin_kW', {}, ...
        'peak_kW', {}, ...
        'final_day', {});

    overrun_detail_days = detail_days;

    for kk = 1:nDays
        dc = day_cache(kk);

        month_id = local_get_month_id_from_abs_day_4y(dc.abs_day);

        if isempty(current_month_id) || month_id ~= current_month_id
            current_month_id = month_id;
            current_month_peak = 0;
        end

        soc_start_of_day = state_bess.cell_state.SOC;

        if kk == nDays
            soc_start_of_final_day = soc_start_of_day;
        end

        contract_state = struct();
        contract_state.P_contract_kW = contract_kW;
        contract_state.P_month_max_so_far_kW = current_month_peak;
        contract_state.current_day_of_month = mod(dc.abs_day - 1, 30) + 1;

        contract_state.P_grid_hard_cap_kW = 700;

        pars.SoC_initial = state_bess.cell_state.SOC;

        plan_full = ems_day_ahead_planner_milp_contract( ...
            dc.P_load_48h, dc.P_pv_48h, dc.Prices_48h, ...
            pars, tariff, dc.dt_h, contract_state, 15);

        nDay = length(dc.P_load_actual);

        plan_today = plan_full;
        plan_today.trade_buy_mask  = plan_full.trade_buy_mask(1:nDay);
        plan_today.trade_sell_mask = plan_full.trade_sell_mask(1:nDay);
        plan_today.P_ch_plan       = plan_full.P_ch_plan(1:nDay);
        plan_today.P_dis_plan      = plan_full.P_dis_plan(1:nDay);
        plan_today.P_grid_plan     = plan_full.P_grid_plan(1:nDay);
        plan_today.P_curt_plan     = plan_full.P_curt_plan(1:nDay);
        plan_today.SoC_plan        = plan_full.SoC_plan(1:nDay);

        P_bess_dc_req_kW = ems_realtime_decision_dc( ...
            dc.P_pv_dc_actual, dc.P_load_actual, plan_today, pars);

        [dayRes, state_bess] = topology_dc_coupled( ...
            P_bess_dc_req_kW, dc.P_pv_dc_actual, dc.P_load_actual, ...
            dc.Prices_today, pars, state_bess, dc.dt_h);

        actual_grid = (dayRes.E_grid_import(:)) / dc.dt_h;
        actual_peak = max(actual_grid);

        prev_overrun = max(0, current_month_peak - contract_kW);
        current_month_peak = max(current_month_peak, actual_peak);
        new_overrun = max(0, current_month_peak - contract_kW);
        overrun_increment_cost_actual = monthly_overrun_cost_per_kW * (new_overrun - prev_overrun);

        buy_today = dc.Prices_today.buy_huf(:);
        buy_total = buy_today + tariff.distribution_energy_rate_huf_per_kWh + ...
                               tariff.transmission_energy_rate_huf_per_kWh;

        energy_cost_actual = sum(buy_total(:) .* actual_grid(:)) * dc.dt_h;
        deg_cost_actual = pars.degradation_cost_per_kWh * ...
                          sum(dayRes.E_stored(:) + dayRes.E_discharged(:));

        daily_peak_no_bess(kk)    = dc.no_bess_peak;
        daily_peak_with_bess(kk)  = actual_peak;
        daily_energy_cost(kk)     = energy_cost_actual;
        daily_deg_cost(kk)        = deg_cost_actual;
        daily_overrun_cost(kk)    = overrun_increment_cost_actual;
        daily_total_cost(kk)      = energy_cost_actual + deg_cost_actual + overrun_increment_cost_actual;
        daily_bess_throughput(kk) = sum(dayRes.E_stored(:) + dayRes.E_discharged(:));
        daily_planned_peak(kk)    = plan_today.P_month_peak_candidate;

        % -----------------------------------------------------------------
        % Részletes diagnosztikai napok mentése
        % Ez nem módosítja a szimuláció működését, csak eltárolja az adott
        % nap plan/res/load/pv/price adatait későbbi plottoláshoz.
        % -----------------------------------------------------------------
        if store_detail
            overrun_margin_kW = actual_peak - contract_kW;
            is_requested_detail_day = ismember(kk, detail_day_indices);
            is_overrun_day = overrun_margin_kW > detail_cfg.overrun_tolerance_kW;

            if is_requested_detail_day || is_overrun_day || kk == nDays
                day_detail = struct();
                day_detail.day_index = kk;
                day_detail.abs_day = dc.abs_day;
                day_detail.overrun_margin_kW = overrun_margin_kW;
                day_detail.peak_kW = actual_peak;

                day_detail.final_day = struct();
                day_detail.final_day.plan = plan_today;
                day_detail.final_day.res = dayRes;
                day_detail.final_day.load = dc.P_load_actual;
                day_detail.final_day.pv = dc.P_pv_dc_actual;
                day_detail.final_day.price = dc.Prices_today;
                day_detail.final_day.soc_start = soc_start_of_day;

                if kk == nDays
                    plot_plan = plan_today;
                    plot_res = dayRes;
                    plot_load = dc.P_load_actual;
                    plot_pv = dc.P_pv_dc_actual;
                    plot_price = dc.Prices_today;
                end

                if is_requested_detail_day
                    day_detail.type = 'representative';
                    detail_days(end+1) = day_detail; %#ok<AGROW>
                end

                if is_overrun_day
                    day_detail.type = 'overrun';
                    overrun_detail_days(end+1) = day_detail; %#ok<AGROW>

                    [~, ord_over] = sort([overrun_detail_days.overrun_margin_kW], 'descend');
                    overrun_detail_days = overrun_detail_days(ord_over);

                    if numel(overrun_detail_days) > detail_cfg.max_overrun_days
                        overrun_detail_days = overrun_detail_days(1:detail_cfg.max_overrun_days);
                    end
                end
            end
        end
    end

    contract_cost_period = (nDays / tariff.days_in_year) * ...
        (tariff.annual_contracted_power_fee_huf_per_kW * contract_kW + tariff.annual_base_fee_huf);

    result = struct();
    result.contract_kW = contract_kW;
    result.energy_cost_period_huf = sum(daily_energy_cost);
    result.degradation_cost_period_huf = sum(daily_deg_cost);
    result.overrun_cost_period_huf = sum(daily_overrun_cost);
    result.contract_cost_period_huf = contract_cost_period;
    result.total_cost_period_huf = result.energy_cost_period_huf + ...
                                   result.degradation_cost_period_huf + ...
                                   result.overrun_cost_period_huf + ...
                                   result.contract_cost_period_huf;

    result.daily_peak_no_bess = daily_peak_no_bess;
    result.daily_peak_with_bess = daily_peak_with_bess;
    result.daily_energy_cost = daily_energy_cost;
    result.daily_deg_cost = daily_deg_cost;
    result.daily_overrun_cost = daily_overrun_cost;
    result.daily_total_cost = daily_total_cost;
    result.daily_bess_throughput = daily_bess_throughput;
    result.daily_planned_peak = daily_planned_peak;
    result.daily_ref_contract = daily_ref_contract;
    result.days_axis = [day_cache.abs_day];

    result.final_day = struct();
    result.final_day.plan = plot_plan;
    result.final_day.res = plot_res;
    result.final_day.load = plot_load;
    result.final_day.pv = plot_pv;
    result.final_day.price = plot_price;
    result.final_day.soc_start = soc_start_of_final_day;

    result.detail_days = detail_days;
    result.overrun_detail_days = overrun_detail_days;
    result.detail_cfg = detail_cfg;
end


% =========================================================================
% 30 NAPOS HÓNAPINDEX A JELENLEGI SZIMULÁCIÓS KERETHEZ
% =========================================================================
function month_id = local_get_month_id_from_abs_day_4y(abs_day)
    month_id = floor((abs_day - 1) / 30) + 1;
end


% =========================================================================
% ÁBRÁK
% =========================================================================
function plot_contract_search_summary_4y(search_result)

    hist = search_result.proxy_history.history;
    proxy_contracts = [hist.contract_kW];
    proxy_costs     = [hist.total_cost_huf];

    [proxy_contracts_sorted, idx_sort] = sort(proxy_contracts);
    proxy_costs_sorted = proxy_costs(idx_sort);
    [proxy_contracts_unique, ia] = unique(proxy_contracts_sorted, 'last');
    proxy_costs_unique = proxy_costs_sorted(ia);

    validation_results = search_result.validation_results;
    val_contracts = [validation_results.contract_kW];
    val_total     = [validation_results.total_cost_period_huf];
    val_energy    = [validation_results.energy_cost_period_huf];
    val_deg       = [validation_results.degradation_cost_period_huf];
    val_over      = [validation_results.overrun_cost_period_huf];
    val_contractc = [validation_results.contract_cost_period_huf];
    val_runtime   = [validation_results.runtime_s];

    [val_contracts, idxv] = sort(val_contracts);
    val_total     = val_total(idxv);
    val_energy    = val_energy(idxv);
    val_deg       = val_deg(idxv);
    val_over      = val_over(idxv);
    val_contractc = val_contractc(idxv);
    val_runtime   = val_runtime(idxv);

    figure('Name', '4 éves contract keresés összesítő', 'Position', [80, 80, 1350, 900]);

    subplot(2,2,1); hold on; grid on;
    plot(proxy_contracts_unique, proxy_costs_unique, 'k--o', 'LineWidth', 1.5, 'DisplayName', 'Proxy költség');
    plot(val_contracts, val_total, 'b-o', 'LineWidth', 2, 'DisplayName', 'Validált költség');
    xline(search_result.best_contract_kW, 'r--', 'LineWidth', 1.5, ...
        'DisplayName', sprintf('Optimum = %.0f kW', search_result.best_contract_kW));
    xlabel('Contract [kW]');
    ylabel('Költség [HUF]');
    title('Contract keresés');
    legend('Location', 'best');

    subplot(2,2,2); hold on; grid on;
    plot(val_contracts, val_energy,    'k-', 'LineWidth', 1.5, 'DisplayName', 'Energia');
    plot(val_contracts, val_deg,       'b-', 'LineWidth', 1.5, 'DisplayName', 'Degradáció');
    plot(val_contracts, val_over,      'r-', 'LineWidth', 1.5, 'DisplayName', 'Overrun');
    plot(val_contracts, val_contractc, 'm-', 'LineWidth', 1.5, 'DisplayName', 'Fix contract');
    xlabel('Contract [kW]');
    ylabel('Költség [HUF]');
    title('Költségkomponensek');
    legend('Location', 'best');

    subplot(2,2,3); hold on; grid on;
    max_peak = arrayfun(@(s) max(s.daily_peak_with_bess), validation_results);
    mean_peak = arrayfun(@(s) mean(s.daily_peak_with_bess), validation_results);
    p95_peak = arrayfun(@(s) prctile(s.daily_peak_with_bess, 95), validation_results);
    max_peak = max_peak(idxv);
    mean_peak = mean_peak(idxv);
    p95_peak = p95_peak(idxv);

    plot(val_contracts, max_peak, 'b-o', 'LineWidth', 1.5, 'DisplayName', 'Max peak');
    plot(val_contracts, mean_peak, 'k-s', 'LineWidth', 1.5, 'DisplayName', 'Átlag peak');
    plot(val_contracts, p95_peak, 'c-^', 'LineWidth', 1.5, 'DisplayName', 'P95 peak');
    xline(search_result.best_contract_kW, 'r--', 'LineWidth', 1.5, 'DisplayName', 'Optimum');
    xlabel('Contract [kW]');
    ylabel('Peak [kW]');
    title('Peak statisztikák');
    legend('Location', 'best');

    subplot(2,2,4); hold on; grid on;
    bar(val_contracts, val_runtime, 'FaceColor', [0.2 0.6 0.8], 'DisplayName', 'Runtime');
    xlabel('Contract [kW]');
    ylabel('Futásidő [s]');
    title('Validációs futásidők');
end


function plot_full_horizon_summary_4y(full_result, best_contract)

    days_axis = full_result.days_axis(:).';

    daily_peak_no_bess    = full_result.daily_peak_no_bess(:).';
    daily_peak_with_bess  = full_result.daily_peak_with_bess(:).';
    daily_energy_cost     = full_result.daily_energy_cost(:).';
    daily_deg_cost        = full_result.daily_deg_cost(:).';
    daily_overrun_cost    = full_result.daily_overrun_cost(:).';
    daily_total_cost      = full_result.daily_total_cost(:).';
    daily_bess_throughput = full_result.daily_bess_throughput(:).';
    daily_planned_peak    = full_result.daily_planned_peak(:).';
    daily_ref_contract    = full_result.daily_ref_contract(:).';

    figure('Name', 'Teljes 4 éves futás összesítő', 'Position', [120, 80, 1400, 980]);

    subplot(4,1,1); hold on; grid on;
    plot(days_axis, daily_peak_no_bess,   'k-', 'LineWidth', 1.0, 'DisplayName', 'Peak BESS nélkül');
    plot(days_axis, daily_peak_with_bess, 'b-', 'LineWidth', 1.2, 'DisplayName', 'Peak BESS-sel');
    plot(days_axis, daily_planned_peak,   'm-', 'LineWidth', 1.0, 'DisplayName', 'MILP peak jelölt');
    yline(best_contract, 'r--', 'LineWidth', 1.5, 'DisplayName', sprintf('Contract = %.0f kW', best_contract));
    ylabel('Peak [kW]');
    title('Napi peak-ek a teljes időszakon');
    legend('Location', 'best');

    subplot(4,1,2); hold on; grid on;
    plot(days_axis, daily_energy_cost,  'k-', 'LineWidth', 1.0, 'DisplayName', 'Energia');
    plot(days_axis, daily_deg_cost,     'b-', 'LineWidth', 1.0, 'DisplayName', 'Degradáció');
    plot(days_axis, daily_overrun_cost, 'r-', 'LineWidth', 1.0, 'DisplayName', 'Overrun');
    plot(days_axis, daily_total_cost,   'm-', 'LineWidth', 1.5, 'DisplayName', 'Összes napi költség');
    ylabel('Költség [HUF]');
    title('Napi költségek');
    legend('Location', 'best');

    subplot(4,1,3); hold on; grid on;
    bar(days_axis, daily_bess_throughput, 'FaceColor', [0.2 0.6 0.8], 'EdgeColor', 'none');
    ylabel('kWh/nap');
    title('Napi BESS throughput');

    subplot(4,1,4); hold on; grid on;
    plot(days_axis, daily_planned_peak,  'm-', 'LineWidth', 1.2, 'DisplayName', 'MILP peak jelölt');
    plot(days_axis, daily_ref_contract,  'r--', 'LineWidth', 1.2, 'DisplayName', 'Contract');
    plot(days_axis, daily_peak_with_bess,'b:', 'LineWidth', 1.2, 'DisplayName', 'Tényleges peak');
    ylabel('Teljesítmény [kW]');
    xlabel('Nap index');
    title('Peak és contract viszony');
    legend('Location', 'best');
end


function plot_final_day_detail_4y(full_result, pars, day_label)

    if nargin < 3 || isempty(day_label)
        day_label = 'Utolsó nap';
    end

    if isempty(full_result.final_day.plan)
        return;
    end

    plot_plan  = full_result.final_day.plan;
    plot_res   = full_result.final_day.res;
    plot_load  = full_result.final_day.load;
    plot_pv    = full_result.final_day.pv;
    plot_price = full_result.final_day.price;
    soc_start  = full_result.final_day.soc_start;

    time_hours = linspace(0, 24, length(plot_load));
    dt_plot = 24 / length(plot_load);

    % Tényleges hálózati import teljesítmény [kW]
    P_grid_import = plot_res.E_grid_import(:) / dt_plot;

    figure('Name', [day_label, ' részletes nézet'], 'Position', [100, 60, 1250, 1100]);

    % =====================================================================
    % 1) Teljesítményáramlások
    % =====================================================================
    subplot(4,1,1); hold on; grid on;
    title([day_label, ': teljesítményáramlások']);

    P_pv_ac = plot_pv * pars.inv_eta;
    P_pv_to_load = min(P_pv_ac, plot_load);
    residual_after_pv = max(plot_load - P_pv_to_load, 0);

    P_bess_to_load = min(plot_res.E_discharged / dt_plot, residual_after_pv);
    P_grid_to_load = max(plot_load - P_pv_to_load - P_bess_to_load, 0);
    P_bess_charge = plot_res.E_stored / dt_plot;

    h = area(time_hours, [P_pv_to_load', P_bess_to_load', P_grid_to_load']);
    h(1).FaceColor = [0.4660 0.6740 0.1880]; h(1).DisplayName = 'PV -> Load';
    h(2).FaceColor = [0.0000 0.4470 0.7410]; h(2).DisplayName = 'BESS -> Load';
    h(3).FaceColor = [0.6350 0.0780 0.1840]; h(3).DisplayName = 'Grid -> Load';

    plot(time_hours, P_bess_charge, 'Color', [0.9290 0.6940 0.1250], ...
        'LineWidth', 2, 'DisplayName', 'BESS töltés');
    plot(time_hours, plot_load, 'k-', 'LineWidth', 1.2, 'DisplayName', 'Összes load');

    yline(plot_plan.P_contract, 'r--', 'LineWidth', 1.5, 'DisplayName', 'Contract');

    ylabel('Teljesítmény [kW]');
    xlim([0 24]);
    legend('Location', 'northeastoutside');

    % =====================================================================
    % 2) Ár és töltési/kisütési ablakok
    % =====================================================================
    subplot(4,1,2); hold on; grid on;
    title([day_label, ': ár és töltési/kisütési ablakok']);

    plot(time_hours, plot_price.buy_huf, 'k', 'LineWidth', 1.5, 'DisplayName', 'Vételi ár');

    buy_idx = find(plot_plan.trade_buy_mask);
    if ~isempty(buy_idx)
        plot(time_hours(buy_idx), plot_price.buy_huf(buy_idx), 'g.', ...
            'MarkerSize', 15, 'DisplayName', 'Töltési ablak');
    end

    sell_idx = find(plot_plan.trade_sell_mask);
    if ~isempty(sell_idx)
        plot(time_hours(sell_idx), plot_price.buy_huf(sell_idx), 'r.', ...
            'MarkerSize', 15, 'DisplayName', 'Kisütési ablak');
    end

    ylabel('Ár [HUF/kWh]');
    xlim([0 24]);
    legend('Location', 'best');

    % =====================================================================
    % 3) Hálózati import vs. lekötött teljesítmény
    % =====================================================================
    subplot(4,1,3); hold on; grid on;
    title([day_label, ': hálózatból felvett teljesítmény és contract']);

    plot(time_hours, P_grid_import, 'k-', 'LineWidth', 1.5, ...
        'DisplayName', 'Grid import');
    yline(plot_plan.P_contract, 'r--', 'LineWidth', 1.5, ...
        'DisplayName', 'Contract');

    ylabel('Teljesítmény [kW]');
    xlim([0 24]);
    legend('Location', 'best');

    % =====================================================================
    % 4) SOC és BESS teljesítmény
    % =====================================================================
    subplot(4,1,4); yyaxis left; hold on; grid on;
    title([day_label, ': SOC és BESS teljesítmény']);

    E_net_kWh = plot_res.E_stored - plot_res.E_discharged;
    SOC_approx = soc_start + cumsum(E_net_kWh) / pars.E_cap_nom;
    plot(time_hours, SOC_approx * 100, 'b', 'LineWidth', 2, 'DisplayName', 'SOC');

    ylabel('SOC [%]');
    ylim([0 100]);

    yyaxis right;
    bar(time_hours, plot_res.E_bess_dc / dt_plot, ...
        'FaceColor', [0.3010 0.7450 0.9330], ...
        'EdgeColor', 'none', 'BarWidth', 1, ...
        'DisplayName', 'BESS DC P');

    ylabel('BESS P [kW]');
    xlabel('Idő [óra]');
    xlim([0 24]);
    legend('Location', 'best');
end


% =========================================================================
% SEGÉD NORMALIZÁLÁS ÉS KMEANS
% =========================================================================
function Z = local_zscore(X)
    mu = mean(X, 1);
    sig = std(X, 0, 1);
    sig(sig < 1e-12) = 1;
    Z = (X - mu) ./ sig;
end


function [idx, centers] = local_kmeans_basic(X, K, maxIter)

    [N, D] = size(X);

    rng(42);
    perm = randperm(N, K);
    centers = X(perm, :);

    idx = ones(N,1);

    for it = 1:maxIter
        dist = zeros(N, K);
        for k = 1:K
            diff = X - centers(k,:);
            dist(:,k) = sum(diff.^2, 2);
        end
        [~, idx_new] = min(dist, [], 2);

        if all(idx_new == idx) && it > 1
            break;
        end
        idx = idx_new;

        new_centers = zeros(K, D);
        for k = 1:K
            members = X(idx == k, :);
            if isempty(members)
                new_centers(k,:) = X(randi(N), :);
            else
                new_centers(k,:) = mean(members, 1);
            end
        end

        if max(abs(new_centers(:) - centers(:))) < 1e-8
            centers = new_centers;
            break;
        end

        centers = new_centers;
    end
end

function plot_selected_day_details_4y(full_result, pars)
% PLOT_SELECTED_DAY_DETAILS_4Y
%
% Meghívja a meglévő részletes napi plotolót:
%   1) a legnagyobb túllépéses napokra,
%   2) néhány reprezentáns / validációs napra.
%
% A szimulációt nem futtatja újra, csak a run_full_horizon_for_fixed_contract
% által eltárolt napi részleteket használja.

    fprintf('\n--- RÉSZLETES DIAGNOSZTIKAI NAPI ÁBRÁK ---\n');

    if isfield(full_result, 'overrun_detail_days') && ~isempty(full_result.overrun_detail_days)
        over_days = full_result.overrun_detail_days;

        fprintf('Túllépéses részletes napok száma: %d\n', numel(over_days));

        for i = 1:numel(over_days)
            tmp = struct();
            tmp.final_day = over_days(i).final_day;

            label = sprintf('Túllépéses nap | day\\_cache index = %d | abs day = %d | peak = %.1f kW | túllépés = %.1f kW', ...
                over_days(i).day_index, ...
                over_days(i).abs_day, ...
                over_days(i).peak_kW, ...
                over_days(i).overrun_margin_kW);

            plot_final_day_detail_4y(tmp, pars, label);
        end
    else
        fprintf('Nem volt eltárolt túllépéses részletes nap.\n');
    end

    if isfield(full_result, 'detail_days') && ~isempty(full_result.detail_days)
        rep_days = full_result.detail_days;

        if isfield(full_result, 'overrun_detail_days') && ~isempty(full_result.overrun_detail_days)
            over_idx = [full_result.overrun_detail_days.day_index];
            rep_idx = [rep_days.day_index];
            rep_days = rep_days(~ismember(rep_idx, over_idx));
        end

        if isempty(rep_days)
            fprintf('Nincs külön reprezentáns nap, ami nem szerepelt már túllépéses napként.\n');
            return;
        end

        max_rep_plots = 8;
        if isfield(full_result, 'detail_cfg') && ...
           isfield(full_result.detail_cfg, 'max_representative_plots')
            max_rep_plots = full_result.detail_cfg.max_representative_plots;
        end

        nPlot = min(max_rep_plots, numel(rep_days));

        fprintf('Reprezentáns részletes napok plottolása: %d db\n', nPlot);

        for i = 1:nPlot
            tmp = struct();
            tmp.final_day = rep_days(i).final_day;

            label = sprintf('Reprezentáns nap | day\\_cache index = %d | abs day = %d | peak = %.1f kW | margin = %.1f kW', ...
                rep_days(i).day_index, ...
                rep_days(i).abs_day, ...
                rep_days(i).peak_kW, ...
                rep_days(i).overrun_margin_kW);

            plot_final_day_detail_4y(tmp, pars, label);
        end
    else
        fprintf('Nem volt eltárolt reprezentáns részletes nap.\n');
    end
end
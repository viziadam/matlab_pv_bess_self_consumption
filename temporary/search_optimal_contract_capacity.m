% function search_result = search_optimal_contract_capacity(day_cache, rep_set_proxy, rep_set_valid, pars, tariff, search_cfg)
% % SEARCH_OPTIMAL_CONTRACT_CAPACITY
% % Tiszta felező kereséses contract optimumkereső.
% %
% % JAVÍTOTT LOGIKA:
% % - a contract kereséshez a validációs napokhoz tartozó TELJES hónapokat használjuk
% % - az overrun költséget havi maximum alapján számoljuk
% % - a fix lekötött teljesítménydíjat havi alapon évesítjük
% % - az energia- és degradációs költséget havi blokkokból évesítjük
% %
% % A kompatibilitás miatt a függvénynév és a fő interfész változatlan marad.
% 
%     if ~isfield(search_cfg, 'contract_min_kW');    search_cfg.contract_min_kW = 400; end
%     if ~isfield(search_cfg, 'contract_max_kW');    search_cfg.contract_max_kW = 1200; end
%     if ~isfield(search_cfg, 'final_interval_kW');  search_cfg.final_interval_kW = 20; end
%     if ~isfield(search_cfg, 'fine_step_kW');       search_cfg.fine_step_kW = 10; end
%     if ~isfield(search_cfg, 'verbose');            search_cfg.verbose = true; end
% 
%     contract_min = search_cfg.contract_min_kW;
%     contract_max = search_cfg.contract_max_kW;
%     verbose = search_cfg.verbose;
% 
%     % ------------------------------------------------------------------
%     % A szétszórt validációs napokat teljes hónapblokkokra bővítjük
%     % ------------------------------------------------------------------
%     validation_day_indices_full_months = local_expand_validation_days_to_full_months( ...
%         rep_set_valid.validation_day_indices, day_cache);
% 
%     if verbose
%         fprintf('\n=== KULSO CONTRACT KERESÉS ===\n');
%         fprintf('Fix keresési tartomány: [%.0f, %.0f] kW\n', contract_min, contract_max);
%         fprintf('Keresési mód: tiszta felező intervallum-szűkítés\n');
%         fprintf('A kereséshez használt napok száma (teljes hónapokra bővítve): %d\n', ...
%             numel(validation_day_indices_full_months));
%         fprintf('A kereséshez használt hónapok száma: %d\n', ...
%             numel(unique(arrayfun(@(ii) local_get_month_id_from_abs_day(day_cache(ii).abs_day), ...
%             validation_day_indices_full_months))));
%     end
% 
%     cost_fun = @(c) evaluate_contract_on_validation_days( ...
%         c, day_cache, validation_day_indices_full_months, pars, tariff, false);
% 
%     search_log = local_contract_search_interval_halving( ...
%         [contract_min, contract_max], ...
%         search_cfg.final_interval_kW, ...
%         search_cfg.fine_step_kW, ...
%         cost_fun, ...
%         verbose);
% 
%     best_contract = search_log.best_contract_kW;
% 
%     if verbose
%         fprintf('\n=== KERESÉS VÉGE ===\n');
%         fprintf('Talált optimális contract: %.0f kW\n', best_contract);
%         fprintf('Legjobb költség: %.2f HUF\n', search_log.best_cost_huf);
%     end
% 
%     t_final = tic;
%     best_detail = evaluate_contract_on_validation_days( ...
%         best_contract, day_cache, validation_day_indices_full_months, pars, tariff, true);
%     best_detail.runtime_s = toc(t_final);
% 
%     validation_results = best_detail;
% 
%     search_result = struct();
%     search_result.best_contract_kW = best_contract;
%     search_result.proxy_history = search_log;
%     search_result.validation_results = validation_results;
%     search_result.best_validation_result = best_detail;
%     search_result.contract_bounds_kW = [contract_min, contract_max];
%     search_result.start_guess_kW = 10 * round(((contract_min + contract_max) / 2) / 10);
%     search_result.validation_day_indices_full_months = validation_day_indices_full_months;
% end
% 
% 
% function search_log = local_contract_search_interval_halving(bounds_kW, final_interval_kW, fine_step_kW, cost_fun, verbose)
% % LOCAL_CONTRACT_SEARCH_INTERVAL_HALVING
% % Valódi intervallum-felező keresés.
% 
%     history = struct('contract_kW', {}, 'total_cost_huf', {}, 'stage', {});
% 
%     evaluated_contracts = [];
%     evaluated_costs = [];
% 
%     function J = eval_cached(c, stage_name)
%         c = 10 * round(c / 10);
% 
%         idx = find(abs(evaluated_contracts - c) < 1e-9, 1, 'first');
%         if ~isempty(idx)
%             J = evaluated_costs(idx);
%             if verbose
%                 fprintf('  Újraszámolás helyett cache: %.0f kW -> %.2f HUF\n', c, J);
%             end
%             return;
%         end
% 
%         if verbose
%             fprintf('  Kiértékelés: %.0f kW ... ', c);
%         end
% 
%         t0 = tic;
%         out = cost_fun(c);
%         J = out.total_cost_period_huf;
%         t1 = toc(t0);
% 
%         if verbose
%             fprintf('%.2f HUF | runtime = %.2f s\n', J, t1);
%         end
% 
%         evaluated_contracts(end+1) = c; %#ok<AGROW>
%         evaluated_costs(end+1) = J; %#ok<AGROW>
% 
%         row = struct();
%         row.contract_kW = c;
%         row.total_cost_huf = J;
%         row.stage = char(stage_name);
%         history(end+1) = row; %#ok<AGROW>
%     end
% 
%     L = 10 * round(bounds_kW(1) / 10);
%     R = 10 * round(bounds_kW(2) / 10);
% 
%     iter = 0;
% 
%     if verbose
%         fprintf('\n--- FELEZŐ KERESÉS INDUL ---\n');
%     end
% 
%     while (R - L) > final_interval_kW
%         iter = iter + 1;
% 
%         M  = 10 * round(((L + R) / 2) / 10);
%         ML = 10 * round(((L + M) / 2) / 10);
%         MR = 10 * round(((M + R) / 2) / 10);
% 
%         pts = unique([ML, M, MR]);
% 
%         if numel(pts) < 3
%             if verbose
%                 fprintf('\nIteráció %d\n', iter);
%                 fprintf('  Túl kicsi / degenerált intervallum: [%.0f, %.0f]\n', L, R);
%             end
%             break;
%         end
% 
%         if verbose
%             fprintf('\nIteráció %d\n', iter);
%             fprintf('  Aktuális intervallum: [%.0f, %.0f] kW\n', L, R);
%             fprintf('  Vizsgált pontok: ML=%.0f kW | M=%.0f kW | MR=%.0f kW\n', ML, M, MR);
%         end
% 
%         J_ML = eval_cached(ML, 'halving');
%         J_M  = eval_cached(M,  'halving');
%         J_MR = eval_cached(MR, 'halving');
% 
%         if verbose
%             fprintf('  Eredmények:\n');
%             fprintf('    ML = %.0f kW -> %.2f HUF\n', ML, J_ML);
%             fprintf('    M  = %.0f kW -> %.2f HUF\n', M,  J_M);
%             fprintf('    MR = %.0f kW -> %.2f HUF\n', MR, J_MR);
%         end
% 
%         if J_ML <= J_M && J_ML <= J_MR
%             if verbose
%                 fprintf('  Döntés: BAL FÉLINTERVALLUM marad -> [%.0f, %.0f]\n', L, M);
%             end
%             R = M;
% 
%         elseif J_MR <= J_M && J_MR < J_ML
%             if verbose
%                 fprintf('  Döntés: JOBB FÉLINTERVALLUM marad -> [%.0f, %.0f]\n', M, R);
%             end
%             L = M;
% 
%         else
%             if verbose
%                 fprintf('  Döntés: KÖZÉPSŐ FÉLINTERVALLUM marad -> [%.0f, %.0f]\n', ML, MR);
%             end
%             L = ML;
%             R = MR;
%         end
% 
%         L = 10 * round(L / 10);
%         R = 10 * round(R / 10);
% 
%         if R <= L
%             if verbose
%                 fprintf('  Az intervallum összeesett, kilépés.\n');
%             end
%             break;
%         end
%     end
% 
%     if verbose
%         fprintf('\n--- FINOM KIÉRTÉKELÉS A MARADÉK INTERVALLUMBAN ---\n');
%         fprintf('Maradék intervallum: [%.0f, %.0f] kW\n', L, R);
%     end
% 
%     fine_candidates = L:fine_step_kW:R;
%     fine_candidates = unique(10 * round(fine_candidates / 10));
% 
%     if verbose
%         fprintf('Finom jelöltek: ');
%         fprintf('%.0f ', fine_candidates);
%         fprintf('[kW]\n');
%     end
% 
%     best_contract = fine_candidates(1);
%     best_cost = inf;
% 
%     for c = fine_candidates
%         J = eval_cached(c, 'fine');
%         if J < best_cost
%             best_cost = J;
%             best_contract = c;
%         end
%     end
% 
%     if verbose
%         fprintf('\n--- FELEZŐ KERESÉS LEZÁRVA ---\n');
%         fprintf('Legjobb contract: %.0f kW\n', best_contract);
%         fprintf('Legjobb költség: %.2f HUF\n', best_cost);
%     end
% 
%     search_log = struct();
%     search_log.history = history;
%     search_log.best_contract_kW = best_contract;
%     search_log.best_cost_huf = best_cost;
%     search_log.final_interval_kW = [L, R];
% end
% 
% 
% function search_log = local_contract_search_bidir(bounds_kW, step_kW, min_interval_kW, max_iter, cost_fun)
% % LOCAL_CONTRACT_SEARCH_BIDIR
% % Meghagyva kompatibilitás miatt.
% 
%     left = bounds_kW(1);
%     right = bounds_kW(2);
% 
%     history = struct('contract_kW', {}, 'total_cost_huf', {}, 'stage', {});
% 
%     evaluated_contracts = [];
%     evaluated_costs = [];
% 
%     function J = eval_cached(c, stage_name)
%         c = local_round_to_step(c, step_kW);
% 
%         idx = find(abs(evaluated_contracts - c) < 1e-9, 1, 'first');
%         if ~isempty(idx)
%             J = evaluated_costs(idx);
%             return;
%         end
% 
%         out = cost_fun(c);
%         J = out.total_cost_period_huf;
% 
%         evaluated_contracts(end+1) = c; %#ok<AGROW>
%         evaluated_costs(end+1) = J; %#ok<AGROW>
% 
%         row = struct();
%         row.contract_kW = c;
%         row.total_cost_huf = J;
%         row.stage = char(stage_name);
%         history(end+1) = row; %#ok<AGROW>
%     end
% 
%     iter = 0;
% 
%     while (right - left) > min_interval_kW && iter < max_iter
%         iter = iter + 1;
% 
%         mid = local_round_to_step((left + right) / 2, step_kW);
% 
%         c_left  = local_round_to_step(max(left,  mid - step_kW), step_kW);
%         c_mid   = mid;
%         c_right = local_round_to_step(min(right, mid + step_kW), step_kW);
% 
%         J_left  = eval_cached(c_left,  sprintf('iter_%d', iter));
%         J_mid   = eval_cached(c_mid,   sprintf('iter_%d', iter));
%         J_right = eval_cached(c_right, sprintf('iter_%d', iter));
% 
%         fprintf('Iter %d | interval = [%.1f, %.1f] | left=%.1f mid=%.1f right=%.1f\n', ...
%             iter, left, right, c_left, c_mid, c_right);
%         fprintf('         costs: %.2f | %.2f | %.2f\n', J_left, J_mid, J_right);
% 
%         if J_left < J_mid && J_left <= J_right
%             right = c_mid;
%         elseif J_right < J_mid && J_right < J_left
%             left = c_mid;
%         else
%             left  = c_left;
%             right = c_right;
%         end
% 
%         if abs(right - left) < step_kW
%             break;
%         end
%     end
% 
%     final_candidates = unique(local_round_to_step([left, (left+right)/2, right], step_kW));
%     final_costs = zeros(size(final_candidates));
% 
%     for i = 1:numel(final_candidates)
%         final_costs(i) = eval_cached(final_candidates(i), 'final');
%     end
% 
%     [best_cost, idx_best] = min(final_costs);
%     best_contract = final_candidates(idx_best);
% 
%     search_log = struct();
%     search_log.history = history;
%     search_log.best_contract_kW = best_contract;
%     search_log.best_cost_huf = best_cost;
% end
% 
% 
% function c = local_round_to_step(x, step_kW)
%     c = step_kW * round(x / step_kW);
% end
% 
% 
% function result = evaluate_contract_on_proxy_days(contract_kW, day_cache, rep_set_proxy, pars_in, tariff_in)
% % Meghagyva kompatibilitás miatt.
% 
%     pars = pars_in;
%     tariff = tariff_in;
% 
%     rep_idx = rep_set_proxy.all_day_indices(:).';
%     rep_w   = rep_set_proxy.weights(:).';
% 
%     period_days = numel(day_cache);
% 
%     energy_cost_w  = 0;
%     deg_cost_w     = 0;
%     overrun_cost_w = 0;
% 
%     soc_state = 0.5;
%     current_month_id = [];
%     current_month_peak = 0;
% 
%     for kk = 1:numel(rep_idx)
%         ii = rep_idx(kk);
%         w  = rep_w(kk);
%         dc = day_cache(ii);
% 
%         month_id = local_get_month_id_from_abs_day(dc.abs_day);
%         if isempty(current_month_id) || month_id ~= current_month_id
%             current_month_id = month_id;
%             current_month_peak = 0;
%         end
% 
%         contract_state = struct();
%         contract_state.P_contract_kW = contract_kW;
%         contract_state.P_month_max_so_far_kW = current_month_peak;
%         contract_state.current_day_of_month = mod(dc.abs_day - 1, 30) + 1;
% 
%         pars.SoC_initial = soc_state;
% 
%         plan = ems_day_ahead_planner_milp_contract( ...
%             dc.P_load_48h, dc.P_pv_48h, dc.Prices_48h, ...
%             pars, tariff, dc.dt_h, contract_state);
% 
%         nDay = length(dc.P_load_actual);
% 
%         P_grid_day = plan.P_grid_plan(1:nDay);
%         P_ch_day   = plan.P_ch_plan(1:nDay);
%         P_dis_day  = plan.P_dis_plan(1:nDay);
%         SoC_day    = plan.SoC_plan(1:nDay);
% 
%         buy_today = dc.Prices_today.buy_huf(:);
%         buy_total = buy_today + tariff.distribution_energy_rate_huf_per_kWh + ...
%                                tariff.transmission_energy_rate_huf_per_kWh;
% 
%         energy_cost = sum(buy_total(:) .* P_grid_day(:)) * dc.dt_h;
%         deg_cost    = sum(pars.degradation_cost_per_kWh .* (P_ch_day(:) + P_dis_day(:))) * dc.dt_h;
%         overrun_cost = plan.economics.overrun_increment_cost;
% 
%         energy_cost_w  = energy_cost_w  + w * energy_cost;
%         deg_cost_w     = deg_cost_w     + w * deg_cost;
%         overrun_cost_w = overrun_cost_w + w * overrun_cost;
% 
%         current_month_peak = max(current_month_peak, plan.P_month_peak_candidate);
%         soc_state = SoC_day(end);
%         soc_state = min(max(soc_state, pars.SoC_min), pars.SoC_max);
%     end
% 
%     energy_cost_period  = energy_cost_w  * period_days;
%     deg_cost_period     = deg_cost_w     * period_days;
%     overrun_cost_period = overrun_cost_w * period_days;
% 
%     total_months_full_period = numel(unique(arrayfun(@(d) local_get_month_id_from_abs_day(d.abs_day), day_cache)));
%     contract_cost_period = (total_months_full_period / tariff.months_in_year) * ...
%         (tariff.annual_contracted_power_fee_huf_per_kW * contract_kW + tariff.annual_base_fee_huf);
% 
%     result = struct();
%     result.contract_kW = contract_kW;
%     result.energy_cost_period_huf = energy_cost_period;
%     result.degradation_cost_period_huf = deg_cost_period;
%     result.overrun_cost_period_huf = overrun_cost_period;
%     result.contract_cost_period_huf = contract_cost_period;
%     result.total_cost_period_huf = energy_cost_period + deg_cost_period + overrun_cost_period + contract_cost_period;
% end
% 
% 
% function result = evaluate_contract_on_validation_days(contract_kW, day_cache, validation_day_indices, pars_in, tariff_in, store_detail)
% % EVALUATE_CONTRACT_ON_VALIDATION_DAYS
% %
% % JAVÍTOTT, VALÓSÁGKÖZELIBB LOGIKA:
% % - a bemenetként kapott napok teljes hónapblokkokat alkotnak
% % - az energiát és degradációt havi blokkokból évesítjük
% % - az overrun költséget havi maximumból számoljuk
% % - a fix lekötött teljesítménydíjat havi alapon évesítjük
% 
%     if nargin < 6
%         store_detail = false;
%     end
% 
%     pars = pars_in;
%     tariff = tariff_in;
% 
%     validation_day_indices = sort(validation_day_indices(:).');
%     nValDays = numel(validation_day_indices);
% 
%     total_days_full_period = numel(day_cache);
%     total_months_full_period = numel(unique(arrayfun(@(d) local_get_month_id_from_abs_day(d.abs_day), day_cache)));
% 
%     init_params = struct( ...
%         'target_energy_kWh', pars.E_cap_nom, ...
%         'max_power_W', pars.P_rated * 1000, ...
%         'initial_soc', 0.5);
% 
%     [pack_info, state_bess] = bess_pack_model(0, 'init', init_params, 1/12, []);
%     pars.E_cap_nom = pack_info.E_installed_kWh;
% 
%     monthly_overrun_cost_per_kW = tariff.penalty_rate_huf_per_kW_year / tariff.months_in_year;
% 
%     daily_peak_no_bess    = zeros(1, nValDays);
%     daily_peak_with_bess  = zeros(1, nValDays);
%     daily_energy_cost     = zeros(1, nValDays);
%     daily_deg_cost        = zeros(1, nValDays);
%     daily_overrun_cost    = zeros(1, nValDays);
%     daily_total_cost      = zeros(1, nValDays);
%     daily_bess_throughput = zeros(1, nValDays);
%     daily_planned_peak    = zeros(1, nValDays);
%     daily_ref_contract    = contract_kW * ones(1, nValDays);
% 
%     plot_plan = [];
%     plot_res = [];
%     plot_load = [];
%     plot_pv = [];
%     plot_price = [];
%     soc_start_of_final_day = NaN;
% 
%     sampled_month_ids = arrayfun(@(ii) local_get_month_id_from_abs_day(day_cache(ii).abs_day), validation_day_indices);
%     unique_sampled_months = unique(sampled_month_ids);
%     nSampledMonths = numel(unique_sampled_months);
% 
%     monthly_energy_costs   = zeros(1, nSampledMonths);
%     monthly_deg_costs      = zeros(1, nSampledMonths);
%     monthly_overrun_costs  = zeros(1, nSampledMonths);
% 
%     month_pos = 0;
%     current_month_id = [];
%     current_month_peak = 0;
%     current_month_energy = 0;
%     current_month_deg = 0;
% 
%     for kk = 1:nValDays
%         ii = validation_day_indices(kk);
%         dc = day_cache(ii);
% 
%         month_id = local_get_month_id_from_abs_day(dc.abs_day);
% 
%         if isempty(current_month_id) || month_id ~= current_month_id
%             if ~isempty(current_month_id)
%                 monthly_energy_costs(month_pos)  = current_month_energy;
%                 monthly_deg_costs(month_pos)     = current_month_deg;
%                 monthly_overrun_costs(month_pos) = monthly_overrun_cost_per_kW * max(0, current_month_peak - contract_kW);
%             end
% 
%             month_pos = month_pos + 1;
%             current_month_id = month_id;
%             current_month_peak = 0;
%             current_month_energy = 0;
%             current_month_deg = 0;
%         end
% 
%         if kk == nValDays
%             soc_start_of_final_day = state_bess.cell_state.SOC;
%         end
% 
%         contract_state = struct();
%         contract_state.P_contract_kW = contract_kW;
%         contract_state.P_month_max_so_far_kW = current_month_peak;
%         contract_state.current_day_of_month = mod(dc.abs_day - 1, 30) + 1;
% 
%         pars.SoC_initial = state_bess.cell_state.SOC;
% 
%         plan_full = ems_day_ahead_planner_milp_contract( ...
%             dc.P_load_48h, dc.P_pv_48h, dc.Prices_48h, ...
%             pars, tariff, dc.dt_h, contract_state);
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
%         buy_today = dc.Prices_today.buy_huf(:);
%         buy_total = buy_today + tariff.distribution_energy_rate_huf_per_kWh + ...
%                                tariff.transmission_energy_rate_huf_per_kWh;
% 
%         energy_cost_actual = sum(buy_total(:) .* actual_grid(:)) * dc.dt_h;
%         deg_cost_actual = pars.degradation_cost_per_kWh * ...
%                           sum(dayRes.E_stored(:) + dayRes.E_discharged(:));
% 
%         current_month_peak   = max(current_month_peak, actual_peak);
%         current_month_energy = current_month_energy + energy_cost_actual;
%         current_month_deg    = current_month_deg + deg_cost_actual;
% 
%         daily_peak_no_bess(kk)    = dc.no_bess_peak;
%         daily_peak_with_bess(kk)  = actual_peak;
%         daily_energy_cost(kk)     = energy_cost_actual;
%         daily_deg_cost(kk)        = deg_cost_actual;
%         daily_bess_throughput(kk) = sum(dayRes.E_stored(:) + dayRes.E_discharged(:));
%         daily_planned_peak(kk)    = plan_today.P_month_peak_candidate;
% 
%         if store_detail && kk == nValDays
%             plot_plan = plan_today;
%             plot_res = dayRes;
%             plot_load = dc.P_load_actual;
%             plot_pv = dc.P_pv_dc_actual;
%             plot_price = dc.Prices_today;
%         end
%     end
% 
%     if ~isempty(current_month_id)
%         monthly_energy_costs(month_pos)  = current_month_energy;
%         monthly_deg_costs(month_pos)     = current_month_deg;
%         monthly_overrun_costs(month_pos) = monthly_overrun_cost_per_kW * max(0, current_month_peak - contract_kW);
%     end
% 
%     monthly_overrun_day_vector = zeros(1, nValDays);
%     for m = 1:nSampledMonths
%         idx_m = find(sampled_month_ids == unique_sampled_months(m));
%         if ~isempty(idx_m)
%             monthly_overrun_day_vector(idx_m) = monthly_overrun_costs(m) / numel(idx_m);
%         end
%     end
%     daily_overrun_cost = monthly_overrun_day_vector;
%     daily_total_cost = daily_energy_cost + daily_deg_cost + daily_overrun_cost;
% 
%     period_energy_cost  = mean(monthly_energy_costs)  * total_months_full_period;
%     period_deg_cost     = mean(monthly_deg_costs)     * total_months_full_period;
%     period_overrun_cost = mean(monthly_overrun_costs) * total_months_full_period;
% 
%     contract_cost_period = (total_months_full_period / tariff.months_in_year) * ...
%         (tariff.annual_contracted_power_fee_huf_per_kW * contract_kW + tariff.annual_base_fee_huf);
% 
%     result = struct();
%     result.contract_kW = contract_kW;
%     result.energy_cost_period_huf = period_energy_cost;
%     result.degradation_cost_period_huf = period_deg_cost;
%     result.overrun_cost_period_huf = period_overrun_cost;
%     result.contract_cost_period_huf = contract_cost_period;
%     result.total_cost_period_huf = period_energy_cost + period_deg_cost + period_overrun_cost + contract_cost_period;
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
%     result.days_axis = [day_cache(validation_day_indices).abs_day];
% 
%     result.monthly_energy_costs = monthly_energy_costs;
%     result.monthly_deg_costs = monthly_deg_costs;
%     result.monthly_overrun_costs = monthly_overrun_costs;
%     result.sampled_month_ids = unique_sampled_months;
% 
%     result.final_day = struct();
%     result.final_day.plan = plot_plan;
%     result.final_day.res = plot_res;
%     result.final_day.load = plot_load;
%     result.final_day.pv = plot_pv;
%     result.final_day.price = plot_price;
%     result.final_day.soc_start = soc_start_of_final_day;
% end
% 
% 
% function validation_day_indices_full_months = local_expand_validation_days_to_full_months(validation_day_indices, day_cache)
% % A kiválasztott validációs napokhoz tartozó teljes 30 napos hónapokat visszaadja.
% 
%     validation_day_indices = sort(unique(validation_day_indices(:).'));
%     selected_abs_days = [day_cache(validation_day_indices).abs_day];
%     selected_month_ids = unique(arrayfun(@local_get_month_id_from_abs_day, selected_abs_days));
% 
%     all_abs_days = [day_cache.abs_day];
%     all_month_ids = arrayfun(@local_get_month_id_from_abs_day, all_abs_days);
% 
%     mask = ismember(all_month_ids, selected_month_ids);
%     validation_day_indices_full_months = find(mask);
% end
% 
% 
% function month_id = local_get_month_id_from_abs_day(abs_day)
% % Egyszerű 30 napos hónaplogika a jelenlegi tesztkörnyezethez
%     month_id = floor((abs_day - 1) / 30) + 1;
% end

function search_result = search_optimal_contract_capacity(day_cache, rep_set_proxy, rep_set_valid, pars, tariff, search_cfg)
% SEARCH_OPTIMAL_CONTRACT_CAPACITY
% Tiszta felező kereséses contract optimumkereső.
%
% FONTOS:
% - nincs külön validációs lépés a keresés közben
% - a teljes keresés egyetlen költségfüggvényen fut
% - mindig felezzük az intervallumot
% - mindig csak a kedvezőbb felet tartjuk meg
%
% A kompatibilitás miatt a bemeneti argumentumok nevei maradnak,
% de ebben a módban a kereséshez csak a rep_set_valid.validation_day_indices
% mintát használjuk költségkiértékelésre.

    if ~isfield(search_cfg, 'contract_min_kW');    search_cfg.contract_min_kW = 400; end
    if ~isfield(search_cfg, 'contract_max_kW');    search_cfg.contract_max_kW = 1200; end
    if ~isfield(search_cfg, 'final_interval_kW');  search_cfg.final_interval_kW = 20; end
    if ~isfield(search_cfg, 'fine_step_kW');       search_cfg.fine_step_kW = 10; end
    if ~isfield(search_cfg, 'verbose');            search_cfg.verbose = true; end

    contract_min = search_cfg.contract_min_kW;
    contract_max = search_cfg.contract_max_kW;
    verbose = search_cfg.verbose;

    if verbose
        fprintf('\n=== KULSO CONTRACT KERESÉS ===\n');
        fprintf('Fix keresési tartomány: [%.0f, %.0f] kW\n', contract_min, contract_max);
        fprintf('Keresési mód: tiszta felező intervallum-szűkítés\n');
    end

    % Egyetlen költségfüggvény a kereséshez:
    % a 20 napos reprezentáns halmazon értékelünk.
    cost_fun = @(c) evaluate_contract_on_validation_days( ...
        c, day_cache, rep_set_valid.validation_day_indices, pars, tariff, false);

    search_log = local_contract_search_interval_halving( ...
        [contract_min, contract_max], ...
        search_cfg.final_interval_kW, ...
        search_cfg.fine_step_kW, ...
        cost_fun, ...
        verbose);

    best_contract = search_log.best_contract_kW;

    if verbose
        fprintf('\n=== KERESÉS VÉGE ===\n');
        fprintf('Talált optimális contract: %.0f kW\n', best_contract);
        fprintf('Legjobb költség: %.2f HUF\n', search_log.best_cost_huf);
    end

    % A végén egyszer, részletesen lefuttatjuk ugyanarra a pontra
    t_final = tic;
    best_detail = evaluate_contract_on_validation_days( ...
        best_contract, day_cache, rep_set_valid.validation_day_indices, pars, tariff, true);
    best_detail.runtime_s = toc(t_final);

    % Kompatibilitás a meglévő plotoló / kiértékelő függvényekkel:
    % validation_results maradjon struktúratömb, még ha csak 1 elemű is.
    validation_results = best_detail;

    search_result = struct();
    search_result.best_contract_kW = best_contract;
    search_result.proxy_history = search_log;
    search_result.validation_results = validation_results;
    search_result.best_validation_result = best_detail;
    search_result.contract_bounds_kW = [contract_min, contract_max];
    search_result.start_guess_kW = 10 * round(((contract_min + contract_max) / 2) / 10);
end


function search_log = local_contract_search_interval_halving(bounds_kW, final_interval_kW, fine_step_kW, cost_fun, verbose)
% LOCAL_CONTRACT_SEARCH_INTERVAL_HALVING
% Valódi intervallum-felező keresés.
%
% Logika:
%   [L, R] intervallumból indulunk
%   M  = közép
%   ML = bal felezőpont
%   MR = jobb felezőpont
%
% Kiértékeljük:
%   J(ML), J(M), J(MR)
%
% Döntés:
%   - ha ML a legjobb -> megtartjuk a bal felet: [L, M]
%   - ha MR a legjobb -> megtartjuk a jobb felet: [M, R]
%   - ha M a legjobb  -> megtartjuk a középső felet: [ML, MR]
%
% Ezt ismételjük addig, amíg az intervallum elég kicsi nem lesz.
% A végén a maradék szakaszban finom rácson kiválasztjuk a legjobb pontot.

    history = struct('contract_kW', {}, 'total_cost_huf', {}, 'stage', {});

    evaluated_contracts = [];
    evaluated_costs = [];

    function J = eval_cached(c, stage_name)
        c = 10 * round(c / 10);

        idx = find(abs(evaluated_contracts - c) < 1e-9, 1, 'first');
        if ~isempty(idx)
            J = evaluated_costs(idx);
            if verbose
                fprintf('  Újraszámolás helyett cache: %.0f kW -> %.2f HUF\n', c, J);
            end
            return;
        end

        if verbose
            fprintf('  Kiértékelés: %.0f kW ... ', c);
        end

        t0 = tic;
        out = cost_fun(c);
        J = out.total_cost_period_huf;
        t1 = toc(t0);

        if verbose
            fprintf('%.2f HUF | runtime = %.2f s\n', J, t1);
        end

        evaluated_contracts(end+1) = c; %#ok<AGROW>
        evaluated_costs(end+1) = J; %#ok<AGROW>

        row = struct();
        row.contract_kW = c;
        row.total_cost_huf = J;
        row.stage = char(stage_name);
        history(end+1) = row; %#ok<AGROW>
    end

    L = 10 * round(bounds_kW(1) / 10);
    R = 10 * round(bounds_kW(2) / 10);

    iter = 0;

    if verbose
        fprintf('\n--- FELEZŐ KERESÉS INDUL ---\n');
    end

    while (R - L) > final_interval_kW
        iter = iter + 1;

        M  = 10 * round(((L + R) / 2) / 10);
        ML = 10 * round(((L + M) / 2) / 10);
        MR = 10 * round(((M + R) / 2) / 10);

        pts = unique([ML, M, MR]);

        if numel(pts) < 3
            if verbose
                fprintf('\nIteráció %d\n', iter);
                fprintf('  Túl kicsi / degenerált intervallum: [%.0f, %.0f]\n', L, R);
            end
            break;
        end

        if verbose
            fprintf('\nIteráció %d\n', iter);
            fprintf('  Aktuális intervallum: [%.0f, %.0f] kW\n', L, R);
            fprintf('  Vizsgált pontok: ML=%.0f kW | M=%.0f kW | MR=%.0f kW\n', ML, M, MR);
        end

        J_ML = eval_cached(ML, 'halving');
        J_M  = eval_cached(M,  'halving');
        J_MR = eval_cached(MR, 'halving');

        if verbose
            fprintf('  Eredmények:\n');
            fprintf('    ML = %.0f kW -> %.2f HUF\n', ML, J_ML);
            fprintf('    M  = %.0f kW -> %.2f HUF\n', M,  J_M);
            fprintf('    MR = %.0f kW -> %.2f HUF\n', MR, J_MR);
        end

        if J_ML <= J_M && J_ML <= J_MR
            if verbose
                fprintf('  Döntés: BAL FÉLINTERVALLUM marad -> [%.0f, %.0f]\n', L, M);
            end
            R = M;

        elseif J_MR <= J_M && J_MR < J_ML
            if verbose
                fprintf('  Döntés: JOBB FÉLINTERVALLUM marad -> [%.0f, %.0f]\n', M, R);
            end
            L = M;

        else
            if verbose
                fprintf('  Döntés: KÖZÉPSŐ FÉLINTERVALLUM marad -> [%.0f, %.0f]\n', ML, MR);
            end
            L = ML;
            R = MR;
        end

        L = 10 * round(L / 10);
        R = 10 * round(R / 10);

        if R <= L
            if verbose
                fprintf('  Az intervallum összeesett, kilépés.\n');
            end
            break;
        end
    end

    if verbose
        fprintf('\n--- FINOM KIÉRTÉKELÉS A MARADÉK INTERVALLUMBAN ---\n');
        fprintf('Maradék intervallum: [%.0f, %.0f] kW\n', L, R);
    end

    fine_candidates = L:fine_step_kW:R;
    fine_candidates = unique(10 * round(fine_candidates / 10));

    if verbose
        fprintf('Finom jelöltek: ');
        fprintf('%.0f ', fine_candidates);
        fprintf('[kW]\n');
    end

    best_contract = fine_candidates(1);
    best_cost = inf;

    for c = fine_candidates
        J = eval_cached(c, 'fine');
        if J < best_cost
            best_cost = J;
            best_contract = c;
        end
    end

    if verbose
        fprintf('\n--- FELEZŐ KERESÉS LEZÁRVA ---\n');
        fprintf('Legjobb contract: %.0f kW\n', best_contract);
        fprintf('Legjobb költség: %.2f HUF\n', best_cost);
    end

    search_log = struct();
    search_log.history = history;
    search_log.best_contract_kW = best_contract;
    search_log.best_cost_huf = best_cost;
    search_log.final_interval_kW = [L, R];
end

function result = evaluate_contract_on_validation_days(contract_kW, day_cache, validation_day_indices, pars_in, tariff_in, store_detail)
% EVALUATE_CONTRACT_ON_VALIDATION_DAYS
%
% Egyszerusitett contract kiértékelés.
%
% Lenyeg:
%   - nincs kulon fizikai ujraszimulalas;
%   - nincs bess_pack_model, ems_realtime_decision_dc, topology_dc_coupled;
%   - a koltsegek kozvetlenul a planner kimenetebol szamolodnak;
%   - a vizsgalt idoszak koltsege a validation_day_indices hossza alapjan
%     keszul, peldaul 20 validacios nap eseten 20 napos koltseg;
%   - a havi lekotott teljesitmenydij es a havi overrun jellegu dijak
%     idoszakaranyosan kerulnek figyelembevetelre.

    if nargin < 6
        store_detail = false;
    end

    pars = pars_in;
    tariff = tariff_in;

    % ------------------------------------------------------------------
    % Hianyzo tarifa mezok potlasa
    % ------------------------------------------------------------------
    if ~isfield(tariff, 'distribution_energy_rate_huf_per_kWh')
        tariff.distribution_energy_rate_huf_per_kWh = 8.39;
    end

    if ~isfield(tariff, 'transmission_energy_rate_huf_per_kWh')
        tariff.transmission_energy_rate_huf_per_kWh = 3.39;
    end

    if ~isfield(tariff, 'annual_contracted_power_fee_huf_per_kW')
        tariff.annual_contracted_power_fee_huf_per_kW = 15924;
    end

    if ~isfield(tariff, 'annual_base_fee_huf')
        tariff.annual_base_fee_huf = 216504;
    end

    if ~isfield(tariff, 'penalty_rate_huf_per_kW_year')
        tariff.penalty_rate_huf_per_kW_year = ...
            4.0 * tariff.annual_contracted_power_fee_huf_per_kW;
    end

    if ~isfield(tariff, 'month_days')
        tariff.month_days = 30;
    end

    if ~isfield(pars, 'degradation_cost_per_kWh')
        pars.degradation_cost_per_kWh = 0;
    end

    if ~isfield(pars, 'SoC_initial')
        pars.SoC_initial = 0.5;
    end

    % ------------------------------------------------------------------
    % Validacios napok rendezese
    % ------------------------------------------------------------------
    validation_day_indices = sort(validation_day_indices(:).');
    nValDays = numel(validation_day_indices);

    if nValDays < 1
        error('evaluate_contract_on_validation_days: nincs ervenyes validacios nap.');
    end

    % A vizsgalt idoszak hossza most tenylegesen a validacios napok szama.
    % Peldaul 20 validacios nap eseten 20 napos koltseget szamolunk.
    period_days = nValDays;

    % Havi dijak idoszakaranyos resze.
    % Peldaul 20 nap eseten: 20 / 30 havi resz.
    period_month_fraction = period_days / tariff.month_days;

    monthly_contract_fee_huf_per_kW = ...
        tariff.annual_contracted_power_fee_huf_per_kW / 12;

    monthly_base_fee_huf = tariff.annual_base_fee_huf / 12;

    monthly_overrun_cost_huf_per_kW = ...
        tariff.penalty_rate_huf_per_kW_year / 12;

    % ------------------------------------------------------------------
    % Napi eredmenyek taroloi
    % ------------------------------------------------------------------
    daily_peak_no_bess    = zeros(1, nValDays);
    daily_peak_with_bess  = zeros(1, nValDays);
    daily_energy_cost     = zeros(1, nValDays);
    daily_deg_cost        = zeros(1, nValDays);
    daily_overrun_cost    = zeros(1, nValDays);
    daily_total_cost      = zeros(1, nValDays);
    daily_bess_throughput = zeros(1, nValDays);
    daily_planned_peak    = zeros(1, nValDays);
    daily_ref_contract    = contract_kW * ones(1, nValDays);

    plot_plan = [];
    plot_res = [];
    plot_load = [];
    plot_pv = [];
    plot_price = [];
    soc_start_of_final_day = NaN;

    % Egyszerusitett allapotkovetes:
    % a kovetkezo nap planner indulasi SoC-ja az elozo nap planner szerinti
    % utolso SoC erteke lesz.
    soc_state = pars.SoC_initial;

    % Az egesz vizsgalt idoszak legnagyobb planner szerinti halozati importja.
    % Ebbol szamoljuk az idoszakaranyos overrun koltseget.
    period_peak_with_bess = 0;

    % ------------------------------------------------------------------
    % Napi planner futtatas es napi koltsegszamitas
    % ------------------------------------------------------------------
    for kk = 1:nValDays
        ii = validation_day_indices(kk);
        dc = day_cache(ii);

        nDay = length(dc.P_load_actual);

        contract_state = struct();
        contract_state.P_contract_kW = contract_kW;
        contract_state.P_month_max_so_far_kW = 0;
        contract_state.current_day_of_month = kk;

        pars.SoC_initial = soc_state;

        if kk == nValDays
            soc_start_of_final_day = soc_state;
        end

        % --------------------------------------------------------------
        % Planner futtatasa
        % --------------------------------------------------------------
        plan_full = ems_day_ahead_planner_milp_contract( ...
            dc.P_load_48h, ...
            dc.P_pv_48h, ...
            dc.Prices_48h, ...
            pars, ...
            tariff, ...
            dc.dt_h, ...
            contract_state, ...
            15);

        % --------------------------------------------------------------
        % Csak az elso nap hasznalata a 48 oras tervbol
        % --------------------------------------------------------------
        plan_today = plan_full;

        if isfield(plan_full, 'trade_buy_mask')
            plan_today.trade_buy_mask = plan_full.trade_buy_mask(1:nDay);
        end

        if isfield(plan_full, 'trade_sell_mask')
            plan_today.trade_sell_mask = plan_full.trade_sell_mask(1:nDay);
        end

        plan_today.P_ch_plan   = plan_full.P_ch_plan(1:nDay);
        plan_today.P_dis_plan  = plan_full.P_dis_plan(1:nDay);
        plan_today.P_grid_plan = plan_full.P_grid_plan(1:nDay);
        plan_today.P_curt_plan = plan_full.P_curt_plan(1:nDay);
        plan_today.SoC_plan    = plan_full.SoC_plan(1:nDay);

        % Ha a planner reszletes energiaaramokat is visszaad, azokat is vagjuk.
        if isfield(plan_full, 'P_gload_plan')
            plan_today.P_gload_plan = plan_full.P_gload_plan(1:nDay);
        end

        if isfield(plan_full, 'P_gbatt_plan')
            plan_today.P_gbatt_plan = plan_full.P_gbatt_plan(1:nDay);
        end

        if isfield(plan_full, 'P_pvload_plan')
            plan_today.P_pvload_plan = plan_full.P_pvload_plan(1:nDay);
        end

        if isfield(plan_full, 'P_pvbatt_plan')
            plan_today.P_pvbatt_plan = plan_full.P_pvbatt_plan(1:nDay);
        end

        if isfield(plan_full, 'P_bload_plan')
            plan_today.P_bload_plan = plan_full.P_bload_plan(1:nDay);
        end

        % --------------------------------------------------------------
        % Napi koltsegek kozvetlenul a planner kimenetebol
        % --------------------------------------------------------------
        P_grid_day = plan_today.P_grid_plan(:);
        P_ch_day   = plan_today.P_ch_plan(:);
        P_dis_day  = plan_today.P_dis_plan(:);

        buy_today = dc.Prices_today.buy_huf(:);

        buy_total = buy_today + ...
            tariff.distribution_energy_rate_huf_per_kWh + ...
            tariff.transmission_energy_rate_huf_per_kWh;

        % Energiakoltseg:
        % sum_t( ar_t [HUF/kWh] * P_grid_t [kW] * dt [h] )
        energy_cost_actual = sum(buy_total(:) .* P_grid_day(:)) * dc.dt_h;

        % Degradacios koltseg:
        % egyszerusitett throughput-alapu koltseg a planner toltési es
        % kisütesi teljesitmenyeibol.
        deg_cost_actual = pars.degradation_cost_per_kWh * ...
            sum(P_ch_day(:) + P_dis_day(:)) * dc.dt_h;

        % Napi csucs a planner szerinti halozati importbol.
        actual_peak = max(P_grid_day);

        % Idoszaki csucs frissitese.
        period_peak_with_bess = max(period_peak_with_bess, actual_peak);

        % A napi overrun koltseget itt nem osztjuk szet napokra.
        % Az overrun jellegu dijat az idoszak vegen, az idoszaki csucsbol
        % szamoljuk.
        overrun_increment_cost_actual = 0;

        % BESS napi energiaforgalom a planner alapjan.
        bess_throughput = sum(P_ch_day(:) + P_dis_day(:)) * dc.dt_h;

        % --------------------------------------------------------------
        % Napi eredmenyek mentese
        % --------------------------------------------------------------
        if isfield(dc, 'no_bess_peak')
            daily_peak_no_bess(kk) = dc.no_bess_peak;
        else
            daily_peak_no_bess(kk) = max(dc.P_load_actual(:));
        end

        daily_peak_with_bess(kk)  = actual_peak;
        daily_energy_cost(kk)     = energy_cost_actual;
        daily_deg_cost(kk)        = deg_cost_actual;
        daily_overrun_cost(kk)    = overrun_increment_cost_actual;
        daily_total_cost(kk)      = energy_cost_actual + deg_cost_actual;
        daily_bess_throughput(kk) = bess_throughput;

        if isfield(plan_today, 'P_month_peak_candidate')
            daily_planned_peak(kk) = plan_today.P_month_peak_candidate;
        else
            daily_planned_peak(kk) = actual_peak;
        end

        % Kovetkezo nap kezdo SoC-ja.
        if ~isempty(plan_today.SoC_plan)
            soc_state = plan_today.SoC_plan(end);
            soc_state = min(max(soc_state, pars.SoC_min), pars.SoC_max);
        end

        % --------------------------------------------------------------
        % Plot kompatibilitasi adatok az utolso vizsgalt napra
        % --------------------------------------------------------------
        if store_detail && kk == nValDays
            plot_plan = plan_today;
            plot_load = dc.P_load_actual;
            plot_pv = dc.P_pv_dc_actual;
            plot_price = dc.Prices_today;

            % Egyszeru, planner-alapu "res" struktura.
            % Ez nem fizikai topology eredmeny, hanem a planner napi
            % energiaaramainak konvertalt alakja.
            plot_res = struct();
            plot_res.P_grid_import = P_grid_day;
            plot_res.E_grid_import = P_grid_day * dc.dt_h;
            plot_res.E_stored = P_ch_day * dc.dt_h;
            plot_res.E_discharged = P_dis_day * dc.dt_h;
            plot_res.E_curtailment = plan_today.P_curt_plan(:) * dc.dt_h;
        end
    end

    % ------------------------------------------------------------------
    % Idoszaki koltsegek
    % ------------------------------------------------------------------

    % Energia es degradacio:
    % Mivel most tenylegesen a vizsgalt napokra szamolunk, nem atlagolunk
    % es nem szorozzuk fel a teljes day_cache hosszara.
    period_energy_cost = sum(daily_energy_cost);
    period_deg_cost    = sum(daily_deg_cost);

    % Overrun:
    % A teljes vizsgalt idoszak legnagyobb planner szerinti importcsucsa
    % alapjan szamoljuk, majd a havi overrun dijbol kepezunk idoszakaranyos
    % koltseget.
    period_overrun_kW = max(0, period_peak_with_bess - contract_kW);

    period_overrun_cost = ...
        period_overrun_kW * monthly_overrun_cost_huf_per_kW * period_month_fraction;

    % A napi overrun tombbe kompatibilitasi okbol beirjuk az idoszaki
    % overrun koltseget az utolso naphoz.
    if nValDays > 0
        daily_overrun_cost(end) = period_overrun_cost;
        daily_total_cost(end) = daily_total_cost(end) + period_overrun_cost;
    end

    % Lekotott teljesitmeny es alapdij:
    % Havi dijakbol kepzett vizsgalt idoszaki megfelelo.
    contract_capacity_cost_period = ...
        contract_kW * monthly_contract_fee_huf_per_kW * period_month_fraction;

    base_fee_cost_period = ...
        monthly_base_fee_huf * period_month_fraction;

    contract_cost_period = ...
        contract_capacity_cost_period + base_fee_cost_period;

    total_cost_period = ...
        period_energy_cost + ...
        period_deg_cost + ...
        period_overrun_cost + ...
        contract_cost_period;

    % ------------------------------------------------------------------
    % Kimenet
    % ------------------------------------------------------------------
    result = struct();

    result.contract_kW = contract_kW;

    result.energy_cost_period_huf = period_energy_cost;
    result.degradation_cost_period_huf = period_deg_cost;
    result.overrun_cost_period_huf = period_overrun_cost;
    result.contract_cost_period_huf = contract_cost_period;
    result.total_cost_period_huf = total_cost_period;

    result.contract_capacity_cost_period_huf = contract_capacity_cost_period;
    result.base_fee_cost_period_huf = base_fee_cost_period;

    result.period_days = period_days;
    result.period_month_fraction = period_month_fraction;
    result.period_peak_with_bess_kW = period_peak_with_bess;
    result.period_overrun_kW = period_overrun_kW;

    result.daily_peak_no_bess = daily_peak_no_bess;
    result.daily_peak_with_bess = daily_peak_with_bess;
    result.daily_energy_cost = daily_energy_cost;
    result.daily_deg_cost = daily_deg_cost;
    result.daily_overrun_cost = daily_overrun_cost;
    result.daily_total_cost = daily_total_cost;
    result.daily_bess_throughput = daily_bess_throughput;
    result.daily_planned_peak = daily_planned_peak;
    result.daily_ref_contract = daily_ref_contract;
    result.days_axis = [day_cache(validation_day_indices).abs_day];

    result.final_day = struct();
    result.final_day.plan = plot_plan;
    result.final_day.res = plot_res;
    result.final_day.load = plot_load;
    result.final_day.pv = plot_pv;
    result.final_day.price = plot_price;
    result.final_day.soc_start = soc_start_of_final_day;
end

% function result = evaluate_contract_on_validation_days(contract_kW, day_cache, validation_day_indices, pars_in, tariff_in, store_detail)
% % EVALUATE_CONTRACT_ON_VALIDATION_DAYS
% % 20 napos validáció, ténylegesebb fizikai végrehajtással.
% % A havi overrun költséget növekményes logikával számolja.
% 
%     if nargin < 6
%         store_detail = false;
%     end
% 
%     pars = pars_in;
%     tariff = tariff_in;
% 
%     validation_day_indices = sort(validation_day_indices(:).');
%     nValDays = numel(validation_day_indices);
%     total_days_full_period = numel(day_cache);
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
%     daily_peak_no_bess    = zeros(1, nValDays);
%     daily_peak_with_bess  = zeros(1, nValDays);
%     daily_energy_cost     = zeros(1, nValDays);
%     daily_deg_cost        = zeros(1, nValDays);
%     daily_overrun_cost    = zeros(1, nValDays);
%     daily_total_cost      = zeros(1, nValDays);
%     daily_bess_throughput = zeros(1, nValDays);
%     daily_planned_peak    = zeros(1, nValDays);
%     daily_ref_contract    = contract_kW * ones(1, nValDays);
% 
%     plot_plan = [];
%     plot_res = [];
%     plot_load = [];
%     plot_pv = [];
%     plot_price = [];
%     soc_start_of_final_day = NaN;
% 
%     for kk = 1:nValDays
%         ii = validation_day_indices(kk);
%         dc = day_cache(ii);
% 
%         month_id = local_get_month_id_from_abs_day(dc.abs_day);
% 
%         if isempty(current_month_id) || month_id ~= current_month_id
%             current_month_id = month_id;
%             current_month_peak = 0;
%         end
% 
%         if kk == nValDays
%             soc_start_of_final_day = state_bess.cell_state.SOC;
%         end
% 
%         contract_state = struct();
%         contract_state.P_contract_kW = contract_kW;
%         contract_state.P_month_max_so_far_kW = current_month_peak;
%         contract_state.current_day_of_month = mod(dc.abs_day - 1, 30) + 1;
% 
%         pars.SoC_initial = state_bess.cell_state.SOC;
% 
%         plan_full = ems_day_ahead_planner_milp_contract( ...
%             dc.P_load_48h, dc.P_pv_48h, dc.Prices_48h, ...
%             pars, tariff, dc.dt_h, contract_state);
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
%                                tariff.transmission_energy_rate_huf_per_kWh;
% 
%         energy_cost_actual = sum(buy_total(:) .* actual_grid(:)) * dc.dt_h;
%         deg_cost_actual = pars.degradation_cost_per_kWh * ...
%                           sum(dayRes.E_stored(:) + dayRes.E_discharged(:));
% 
%         daily_peak_no_bess(kk)    = dc.no_bess_peak;
%         daily_peak_with_bess(kk)  = actual_peak;
%         daily_energy_cost(kk)     = energy_cost_actual;
%         daily_deg_cost(kk)        = deg_cost_actual;
%         daily_overrun_cost(kk)    = overrun_increment_cost_actual;
%         daily_total_cost(kk)      = energy_cost_actual + deg_cost_actual + overrun_increment_cost_actual;
%         daily_bess_throughput(kk) = sum(dayRes.E_stored(:) + dayRes.E_discharged(:));
%         daily_planned_peak(kk)    = plan_today.P_month_peak_candidate;
% 
%         if store_detail && kk == nValDays
%             plot_plan = plan_today;
%             plot_res = dayRes;
%             plot_load = dc.P_load_actual;
%             plot_pv = dc.P_pv_dc_actual;
%             plot_price = dc.Prices_today;
%         end
%     end
% 
%     avg_energy_cost  = mean(daily_energy_cost);
%     avg_deg_cost     = mean(daily_deg_cost);
%     avg_overrun_cost = mean(daily_overrun_cost);
% 
%     period_energy_cost  = avg_energy_cost  * total_days_full_period;
%     period_deg_cost     = avg_deg_cost     * total_days_full_period;
%     period_overrun_cost = avg_overrun_cost * total_days_full_period;
% 
%     contract_cost_period = (total_days_full_period / tariff.days_in_year) * ...
%         (tariff.annual_contracted_power_fee_huf_per_kW * contract_kW + tariff.annual_base_fee_huf);
% 
%     result = struct();
%     result.contract_kW = contract_kW;
%     result.energy_cost_period_huf = period_energy_cost;
%     result.degradation_cost_period_huf = period_deg_cost;
%     result.overrun_cost_period_huf = period_overrun_cost;
%     result.contract_cost_period_huf = contract_cost_period;
%     result.total_cost_period_huf = period_energy_cost + period_deg_cost + period_overrun_cost + contract_cost_period;
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
%     result.days_axis = [day_cache(validation_day_indices).abs_day];
% 
%     result.final_day = struct();
%     result.final_day.plan = plot_plan;
%     result.final_day.res = plot_res;
%     result.final_day.load = plot_load;
%     result.final_day.pv = plot_pv;
%     result.final_day.price = plot_price;
%     result.final_day.soc_start = soc_start_of_final_day;
% end


function month_id = local_get_month_id_from_abs_day(abs_day)
% Egyszerű 30 napos hónaplogika a jelenlegi tesztkörnyezethez
    month_id = floor((abs_day - 1) / 30) + 1;
end
% function plan = ems_day_ahead_planner_milp_contract(P_load_f, P_pv_dc_f, Prices, pars, tariff, dt_h, contract_state)
% % EMS_DAY_AHEAD_PLANNER_MILP_CONTRACT
% %
% % A belső MILP NEM keresi a contractot.
% % A contract adott paraméter.
% %
% % Ez a verzió:
% %   - a forecastot lehetőség szerint 1 órás időlépésre aggregálja
% %   - NEM használ 16-22 órás kötelező SoC tartalékot
% %   - NEM kényszeríti a kisütést meghatározott órákban
% %   - a végén a tervet visszaalakítja az eredeti felbontásra
% %
% % Bemenet:
% %   P_load_f        : terhelési forecast [kW]
% %   P_pv_dc_f       : PV DC forecast [kW]
% %   Prices.buy_huf  : vételi ár [HUF/kWh]
% %   pars            : BESS paraméterek
% %   tariff          : tarifa paraméterek
% %   dt_h            : eredeti időlépés [h]
% %   contract_state  : struct
% %       .P_contract_kW
% %       .P_month_max_so_far_kW
% %       .current_day_of_month
% %
% % Kimenet:
% %   plan            : az eredeti időfelbontásra visszanagyított terv
% 
%     % ---------------------------------------------------------------------
%     % HIÁNYZÓ TARIFA MEZŐK PÓTLÁSA
%     % ---------------------------------------------------------------------
%     if ~isfield(tariff, 'distribution_energy_rate_huf_per_kWh')
%         tariff.distribution_energy_rate_huf_per_kWh = 8.39;
%     end
%     if ~isfield(tariff, 'transmission_energy_rate_huf_per_kWh')
%         tariff.transmission_energy_rate_huf_per_kWh = 3.39;
%     end
%     if ~isfield(tariff, 'annual_contracted_power_fee_huf_per_kW')
%         tariff.annual_contracted_power_fee_huf_per_kW = 15924;
%     end
%     if ~isfield(tariff, 'annual_base_fee_huf')
%         tariff.annual_base_fee_huf = 216504;
%     end
%     if ~isfield(tariff, 'contracted_capacity_kW')
%         tariff.contracted_capacity_kW = 350;
%     end
%     if ~isfield(tariff, 'days_in_year')
%         tariff.days_in_year = 365;
%     end
%     if ~isfield(tariff, 'months_in_year')
%         tariff.months_in_year = 12;
%     end
%     if ~isfield(tariff, 'penalty_rate_huf_per_kW_year')
%         tariff.penalty_rate_huf_per_kW_year = 4.0 * tariff.annual_contracted_power_fee_huf_per_kW;
%     end
%     if ~isfield(tariff, 'curtailment_penalty_huf_per_kWh')
%         tariff.curtailment_penalty_huf_per_kWh = 0.0;
%     end
%     if ~isfield(tariff, 'grid_charge_price_quantile')
%         tariff.grid_charge_price_quantile = 0.25;
%     end
%     if ~isfield(tariff, 'noncheap_charge_penalty_huf_per_kWh')
%         tariff.noncheap_charge_penalty_huf_per_kWh = 0.0;
%     end
%     if ~isfield(tariff, 'within_contract_peak_weight_huf_per_kW_month')
%         tariff.within_contract_peak_weight_huf_per_kW_month = 0.0;
%     end
% 
%     % ---------------------------------------------------------------------
%     % EREDETI IDŐFELBONTÁS ELMENTÉSE
%     % ---------------------------------------------------------------------
%     P_load_f_orig  = P_load_f(:);
%     P_pv_dc_f_orig = P_pv_dc_f(:);
%     buy_p_orig     = Prices.buy_huf(:);
% 
%     N_orig = length(P_load_f_orig);
% 
%     % ---------------------------------------------------------------------
%     % 1 ÓRÁS AGGREGÁLÁS, HA LEHETSÉGES
%     % ---------------------------------------------------------------------
%     [P_load_f, P_pv_dc_f, buy_p_market, dt_milp, expand_factor] = ...
%         local_prepare_hourly_forecast(P_load_f_orig, P_pv_dc_f_orig, buy_p_orig, dt_h);
% 
%     N = length(P_load_f);
% 
%     % ---------------------------------------------------------------------
%     % PARAMÉTEREK
%     % ---------------------------------------------------------------------
%     eta_c_path = pars.inv_eta * pars.eta_c * pars.eta_cell;
%     eta_d_path = pars.eta_cell * pars.eta_d * pars.inv_eta;
% 
%     deg_model = build_article_simple_degradation_costs(pars);
%     cost_deg_ch  = deg_model.cost_ch_huf_per_kWh;
%     cost_deg_dis = deg_model.cost_dis_huf_per_kWh;
% 
%     if isfield(pars, 'SoC_initial')
%         SoC_start = pars.SoC_initial;
%     else
%         SoC_start = 0.5;
%     end
% 
% 
%     P_ch_max  = pars.P_chg_max;
%     P_dis_max = pars.P_dis_max;
% 
%     P_contract = contract_state.P_contract_kW;
%     P_month_max_so_far = contract_state.P_month_max_so_far_kW;
% 
%     prev_overrun = max(0, P_month_max_so_far - P_contract);
% 
%     dist_fee = tariff.distribution_energy_rate_huf_per_kWh;
%     trans_fee = tariff.transmission_energy_rate_huf_per_kWh;
%     buy_p_total = buy_p_market + dist_fee + trans_fee;
% 
%     monthly_overrun_cost_per_kW = tariff.penalty_rate_huf_per_kW_year / tariff.months_in_year;
%     within_contract_peak_weight = tariff.within_contract_peak_weight_huf_per_kW_month;
% 
%     P_pv_ac = min(P_pv_dc_f * pars.inv_eta, pars.P_inv_limit_ac);
% 
%     % ---------------------------------------------------------------------
%     % Opcionális nem-olcsó hálózati töltés büntetés
%     % ---------------------------------------------------------------------
%     qcheap = tariff.grid_charge_price_quantile;
%     cheap_threshold = quantile(buy_p_market, qcheap);
%     cheap_mask = buy_p_market <= cheap_threshold;
% 
%     pv_surplus_mask = P_pv_ac > P_load_f;
%     noncheap_charge_penalty = tariff.noncheap_charge_penalty_huf_per_kWh * ...
%                               (~cheap_mask & ~pv_surplus_mask);
% 
%     % ---------------------------------------------------------------------
%     % FONTOS: NINCS 16-22 ÓRÁS KÖTELEZŐ TARTALÉK
%     % ---------------------------------------------------------------------
%     soc_min_vec = pars.SoC_min * ones(N,1);
% 
%     % ---------------------------------------------------------------------
%     % DÖNTÉSI VÁLTOZÓK
%     % ---------------------------------------------------------------------
%     iGrid  = 1:N;
%     iCh    = N+1:2*N;
%     iDis   = 2*N+1:3*N;
%     iSoc   = 3*N+1:4*N;
%     iMode  = 4*N+1:5*N;
%     iCurt  = 5*N+1:6*N;
%     iMonthPeak = 6*N+1;
%     iOverInc   = 6*N+2;
%     nVars = 6*N + 2;
% 
%     % ---------------------------------------------------------------------
%     % CÉLFÜGGVÉNY
%     % ---------------------------------------------------------------------
%     f = zeros(nVars, 1);
%     f(iGrid) = buy_p_total * dt_milp;
%     f(iCh)   = cost_deg_ch  * dt_milp + noncheap_charge_penalty * dt_milp;
%     f(iDis)  = cost_deg_dis * dt_milp;
%     f(iCurt) = tariff.curtailment_penalty_huf_per_kWh * dt_milp;
%     f(iMonthPeak) = within_contract_peak_weight;
%     f(iOverInc)   = monthly_overrun_cost_per_kW;
% 
%     % ---------------------------------------------------------------------
%     % EGYENLŐSÉGI FELTÉTELEK
%     % ---------------------------------------------------------------------
%     % P_grid + P_dis - P_ch - P_curt = P_load - P_pv_ac
%     Aeq_energy = zeros(N, nVars);
%     beq_energy = P_load_f - P_pv_ac;
% 
%     for t = 1:N
%         Aeq_energy(t, iGrid(t)) =  1;
%         Aeq_energy(t, iDis(t))  =  1;
%         Aeq_energy(t, iCh(t))   = -1;
%         Aeq_energy(t, iCurt(t)) = -1;
%     end
% 
%     % SoC dinamika
%     Aeq_soc = zeros(N, nVars);
%     beq_soc = zeros(N, 1);
% 
%     Aeq_soc(1, iSoc(1)) = 1;
%     beq_soc(1) = SoC_start;
% 
%     alpha_ch = (eta_c_path * dt_milp) / pars.E_cap_nom;
%     beta_dis = (dt_milp / eta_d_path) / pars.E_cap_nom;
% 
%     for t = 2:N
%         Aeq_soc(t, iSoc(t))   =  1;
%         Aeq_soc(t, iSoc(t-1)) = -1;
%         Aeq_soc(t, iCh(t-1))  = -alpha_ch;
%         Aeq_soc(t, iDis(t-1)) =  beta_dis;
%     end
% 
%     Aeq = [Aeq_energy; Aeq_soc];
%     beq = [beq_energy; beq_soc];
% 
%     % ---------------------------------------------------------------------
%     % EGYENLŐTLENSÉGI FELTÉTELEK
%     % ---------------------------------------------------------------------
%     A = [];
%     b = [];
% 
%     % Töltés / kisütés szétválasztás
%     A_bin = zeros(2*N, nVars);
%     b_bin = zeros(2*N, 1);
% 
%     for t = 1:N
%         A_bin(t, iCh(t))   = 1;
%         A_bin(t, iMode(t)) = -P_ch_max;
% 
%         A_bin(N+t, iDis(t))  = 1;
%         A_bin(N+t, iMode(t)) = P_dis_max;
%         b_bin(N+t) = P_dis_max;
%     end
% 
%     A = [A; A_bin];
%     b = [b; b_bin];
% 
%     % Curtailment korlát
%     A_curt = zeros(N, nVars);
%     b_curt = zeros(N, 1);
%     for t = 1:N
%         A_curt(t, iCurt(t)) = 1;
%         b_curt(t) = P_pv_ac(t);
%     end
%     A = [A; A_curt];
%     b = [b; b_curt];
% 
%     % Havi peak változó >= minden grid import
%     A_peak = zeros(N, nVars);
%     b_peak = zeros(N, 1);
%     for t = 1:N
%         A_peak(t, iGrid(t)) = 1;
%         A_peak(t, iMonthPeak) = -1;
%     end
%     A = [A; A_peak];
%     b = [b; b_peak];
% 
%     % Overrun increment:
%     % iOverInc >= iMonthPeak - P_contract - prev_overrun
%     % => iMonthPeak - iOverInc <= P_contract + prev_overrun
%     row_over = zeros(1, nVars);
%     row_over(iMonthPeak) = 1;
%     row_over(iOverInc)   = -1;
%     A = [A; row_over];
%     b = [b; P_contract + prev_overrun];
% 
%     % ---------------------------------------------------------------------
%     % ALSÓ/FELSŐ KORLÁTOK
%     % ---------------------------------------------------------------------
%     lb = zeros(nVars, 1);
%     ub = inf(nVars, 1);
% 
% 
%     lb(iSoc) = soc_min_vec;
%     ub(iSoc) = pars.SoC_max;
% 
%     lb(iMode) = 0;
%     ub(iMode) = 1;
% 
%     lb(iMonthPeak) = P_month_max_so_far;
%     lb(iOverInc)   = 0;
% 
%     intcon = iMode;
% 
%     % ---------------------------------------------------------------------
%     % SOLVER
%     % ---------------------------------------------------------------------
%     options = optimoptions('intlinprog', ...
%         'Display', 'off', ...
%         'MaxTime', 15, ...
%         'RelativeGapTolerance', 0.01, ...
%         'IntegerPreprocess', 'advanced', ...
%         'RootLPAlgorithm', 'dual-simplex');
% 
%     [x, fval, exitflag] = intlinprog(f, intcon, A, b, Aeq, beq, lb, ub, options);
% 
%     % ---------------------------------------------------------------------
%     % FALLBACK
%     % ---------------------------------------------------------------------
%     if isempty(x) || exitflag <= 0
%         fallback_grid = max(P_load_f - P_pv_ac, 0);
%         fallback_peak = max(P_month_max_so_far, max(fallback_grid));
%         fallback_over_inc = max(0, max(0, fallback_peak - P_contract) - prev_overrun);
% 
%         plan_hourly = struct();
%         plan_hourly.P_contract = P_contract;
%         plan_hourly.P_month_max_so_far = P_month_max_so_far;
%         plan_hourly.P_month_peak_candidate = fallback_peak;
%         plan_hourly.P_overrun_increment_kW = fallback_over_inc;
% 
%         plan_hourly.trade_buy_mask  = false(1, N);
%         plan_hourly.trade_sell_mask = false(1, N);
% 
%         plan_hourly.P_grid_plan = fallback_grid;
%         plan_hourly.P_ch_plan   = zeros(N, 1);
%         plan_hourly.P_dis_plan  = zeros(N, 1);
%         plan_hourly.P_curt_plan = max(P_pv_ac - P_load_f, 0);
%         plan_hourly.SoC_plan    = SoC_start * ones(N, 1);
% 
%         plan_hourly.exitflag = exitflag;
%         plan_hourly.objective_value = inf;
% 
%         plan_hourly.economics.energy_cost_market = sum(buy_p_market(:) .* plan_hourly.P_grid_plan(:)) * dt_milp;
%         plan_hourly.economics.energy_cost_network = sum((dist_fee + trans_fee) .* plan_hourly.P_grid_plan(:)) * dt_milp;
%         plan_hourly.economics.energy_cost_total = plan_hourly.economics.energy_cost_market + plan_hourly.economics.energy_cost_network;
%         plan_hourly.economics.degradation_cost = 0;
%         plan_hourly.economics.overrun_increment_cost = monthly_overrun_cost_per_kW * fallback_over_inc;
%         plan_hourly.economics.net_cost_operational = inf;
% 
%         plan = local_expand_hourly_plan_to_original(plan_hourly, N_orig, expand_factor);
%         return;
%     end
% 
%     % ---------------------------------------------------------------------
%     % MEGOLDÁS KIBONTÁSA
%     % ---------------------------------------------------------------------
%     P_grid = x(iGrid);
%     P_ch   = x(iCh);
%     P_dis  = x(iDis);
%     SoC    = x(iSoc);
%     P_curt = x(iCurt);
%     P_month_peak_candidate = x(iMonthPeak);
%     P_over_inc = x(iOverInc);
% 
%     plan_hourly = struct();
%     plan_hourly.P_contract = P_contract;
%     plan_hourly.P_month_max_so_far = P_month_max_so_far;
%     plan_hourly.P_month_peak_candidate = P_month_peak_candidate;
%     plan_hourly.P_overrun_increment_kW = P_over_inc;
% 
%     plan_hourly.trade_buy_mask  = (P_ch  > 1e-3).';
%     plan_hourly.trade_sell_mask = (P_dis > 1e-3).';
% 
%     plan_hourly.P_grid_plan = P_grid;
%     plan_hourly.P_ch_plan   = P_ch;
%     plan_hourly.P_dis_plan  = P_dis;
%     plan_hourly.P_curt_plan = P_curt;
%     plan_hourly.SoC_plan    = SoC;
% 
%     plan_hourly.exitflag = exitflag;
%     plan_hourly.objective_value = fval;
% 
%     energy_cost_market  = sum(buy_p_market(:) .* P_grid(:)) * dt_milp;
%     energy_cost_network = sum((dist_fee + trans_fee) .* P_grid(:)) * dt_milp;
%     degradation_cost = ...
%     sum(cost_deg_ch  .* P_ch(:))  * dt_milp + ...
%     sum(cost_deg_dis .* P_dis(:)) * dt_milp;
%     overrun_increment_cost = monthly_overrun_cost_per_kW * P_over_inc;
% 
%     plan_hourly.economics.energy_cost_market = energy_cost_market;
%     plan_hourly.economics.energy_cost_network = energy_cost_network;
%     plan_hourly.economics.energy_cost_total = energy_cost_market + energy_cost_network;
%     plan_hourly.economics.degradation_cost = degradation_cost;
%     plan_hourly.economics.overrun_increment_cost = overrun_increment_cost;
%     plan_hourly.economics.net_cost_operational = ...
%         energy_cost_market + energy_cost_network + degradation_cost + overrun_increment_cost;
% 
%     % ---------------------------------------------------------------------
%     % VISSZAALAKÍTÁS EREDETI FELBONTÁSRA
%     % ---------------------------------------------------------------------
%     plan = local_expand_hourly_plan_to_original(plan_hourly, N_orig, expand_factor);
% end
% 
% 
% % =========================================================================
% % BELSŐ SEGÉDFÜGGVÉNYEK
% % =========================================================================
% function [P_load_h, P_pv_h, buy_h, dt_out, expand_factor] = local_prepare_hourly_forecast(P_load, P_pv, buy_p, dt_in)
% % Ha a bemenet finomabb, mint 1 óra, akkor 1 órára aggregálunk.
% % Ha nem osztható jól, akkor az eredeti felbontás marad.
% 
%     P_load = P_load(:);
%     P_pv   = P_pv(:);
%     buy_p  = buy_p(:);
% 
%     if dt_in <= 0
%         error('local_prepare_hourly_forecast: dt_in must be positive');
%     end
% 
%     expand_factor_real = 1 / dt_in;
%     expand_factor_round = round(expand_factor_real);
% 
%     can_aggregate = abs(expand_factor_real - expand_factor_round) < 1e-9 && expand_factor_round >= 1;
% 
%     if ~can_aggregate
%         P_load_h = P_load;
%         P_pv_h   = P_pv;
%         buy_h    = buy_p;
%         dt_out   = dt_in;
%         expand_factor = 1;
%         return;
%     end
% 
%     if expand_factor_round == 1
%         P_load_h = P_load;
%         P_pv_h   = P_pv;
%         buy_h    = buy_p;
%         dt_out   = dt_in;
%         expand_factor = 1;
%         return;
%     end
% 
%     N = length(P_load);
%     nBlocks = floor(N / expand_factor_round);
% 
%     if nBlocks < 1
%         P_load_h = P_load;
%         P_pv_h   = P_pv;
%         buy_h    = buy_p;
%         dt_out   = dt_in;
%         expand_factor = 1;
%         return;
%     end
% 
%     N_use = nBlocks * expand_factor_round;
% 
%     P_load_use = P_load(1:N_use);
%     P_pv_use   = P_pv(1:N_use);
%     buy_use    = buy_p(1:N_use);
% 
%     P_load_mat = reshape(P_load_use, expand_factor_round, nBlocks);
%     P_pv_mat   = reshape(P_pv_use,   expand_factor_round, nBlocks);
%     buy_mat    = reshape(buy_use,    expand_factor_round, nBlocks);
% 
%     % Teljesítmény forecastokhoz órás átlag
%     P_load_h = mean(P_load_mat, 1).';
%     P_pv_h   = mean(P_pv_mat,   1).';
% 
%     % Árhoz is órás átlag
%     buy_h = mean(buy_mat, 1).';
% 
%     dt_out = 1.0;
%     expand_factor = expand_factor_round;
% 
%     % Ha maradék van, azt elhagyjuk az aggregálásnál,
%     % majd a végén a visszanagyításnál az utolsó értékkel kitöltjük.
% end
% 
% 
% function plan_out = local_expand_hourly_plan_to_original(plan_in, N_orig, expand_factor)
% % Az órás MILP tervet visszanagyítja az eredeti mintaszámra.
% 
%     if expand_factor <= 1
%         plan_out = plan_in;
%         return;
%     end
% 
%     plan_out = plan_in;
% 
%     plan_out.trade_buy_mask  = local_repeat_to_length(logical(plan_in.trade_buy_mask(:)),  N_orig, expand_factor).';
%     plan_out.trade_sell_mask = local_repeat_to_length(logical(plan_in.trade_sell_mask(:)), N_orig, expand_factor).';
% 
%     plan_out.P_grid_plan = local_repeat_to_length(plan_in.P_grid_plan(:), N_orig, expand_factor);
%     plan_out.P_ch_plan   = local_repeat_to_length(plan_in.P_ch_plan(:),   N_orig, expand_factor);
%     plan_out.P_dis_plan  = local_repeat_to_length(plan_in.P_dis_plan(:),  N_orig, expand_factor);
%     plan_out.P_curt_plan = local_repeat_to_length(plan_in.P_curt_plan(:), N_orig, expand_factor);
%     plan_out.SoC_plan    = local_repeat_to_length(plan_in.SoC_plan(:),    N_orig, expand_factor);
% end
% 
% 
% function y = local_repeat_to_length(x, N_target, rep_factor)
% % Minden elemet rep_factor alkalommal ismétel, majd pontos hosszra vág/feltölt.
% 
%     x = x(:);
%     y = repelem(x, rep_factor, 1);
% 
%     if length(y) >= N_target
%         y = y(1:N_target);
%         return;
%     end
% 
%     % ha rövidebb lett, az utolsó értékkel kitöltjük
%     y = [y; repmat(y(end), N_target - length(y), 1)];
% end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% 2. VALTOZAT
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% function plan = ems_day_ahead_planner_milp_contract(P_load_f, P_pv_dc_f, Prices, pars, tariff, dt_h, contract_state)
% % EMS_DAY_AHEAD_PLANNER_MILP_CONTRACT
% %
% % JAVÍTOTT VERZIÓ:
% % - a hálózati töltés külön változóval szerepel
% % - a peak-kockázatos hálózati töltés külön büntetést kap
% % - az overrun továbbra is havi peak alapon számolódik
% % - a MILP így az arbitrage hasznot összeveti az
% %   energiaköltséggel + degradációval + peak-kockázattal
% 
%     % ---------------------------------------------------------------------
%     % HIÁNYZÓ TARIFA MEZŐK PÓTLÁSA
%     % ---------------------------------------------------------------------
%     if ~isfield(tariff, 'distribution_energy_rate_huf_per_kWh')
%         tariff.distribution_energy_rate_huf_per_kWh = 8.39;
%     end
%     if ~isfield(tariff, 'transmission_energy_rate_huf_per_kWh')
%         tariff.transmission_energy_rate_huf_per_kWh = 3.39;
%     end
%     if ~isfield(tariff, 'annual_contracted_power_fee_huf_per_kW')
%         tariff.annual_contracted_power_fee_huf_per_kW = 15924;
%     end
%     if ~isfield(tariff, 'annual_base_fee_huf')
%         tariff.annual_base_fee_huf = 216504;
%     end
%     if ~isfield(tariff, 'contracted_capacity_kW')
%         tariff.contracted_capacity_kW = 350;
%     end
%     if ~isfield(tariff, 'days_in_year')
%         tariff.days_in_year = 365;
%     end
%     if ~isfield(tariff, 'months_in_year')
%         tariff.months_in_year = 12;
%     end
%     if ~isfield(tariff, 'penalty_rate_huf_per_kW_year')
%         tariff.penalty_rate_huf_per_kW_year = 4.0 * tariff.annual_contracted_power_fee_huf_per_kW;
%     end
%     if ~isfield(tariff, 'curtailment_penalty_huf_per_kWh')
%         tariff.curtailment_penalty_huf_per_kWh = 0.0;
%     end
%     if ~isfield(tariff, 'grid_charge_price_quantile')
%         tariff.grid_charge_price_quantile = 0.25;
%     end
%     if ~isfield(tariff, 'noncheap_charge_penalty_huf_per_kWh')
%         tariff.noncheap_charge_penalty_huf_per_kWh = 0.0;
%     end
%     if ~isfield(tariff, 'within_contract_peak_weight_huf_per_kW_month')
%         tariff.within_contract_peak_weight_huf_per_kW_month = ...
%             tariff.annual_contracted_power_fee_huf_per_kW / tariff.months_in_year;
%     end
%     if ~isfield(tariff, 'risky_grid_charge_penalty_multiplier')
%         tariff.risky_grid_charge_penalty_multiplier = 1.0;
%     end
%     if ~isfield(tariff, 'terminal_soc_weight_huf_per_soc')
%         tariff.terminal_soc_weight_huf_per_soc = 0.0;
%     end
% 
%     % ---------------------------------------------------------------------
%     % EREDETI IDŐFELBONTÁS ELMENTÉSE
%     % ---------------------------------------------------------------------
%     P_load_f_orig  = P_load_f(:);
%     P_pv_dc_f_orig = P_pv_dc_f(:);
%     buy_p_orig     = Prices.buy_huf(:);
% 
%     N_orig = length(P_load_f_orig);
% 
%     % ---------------------------------------------------------------------
%     % 1 ÓRÁS AGGREGÁLÁS, HA LEHETSÉGES
%     % ---------------------------------------------------------------------
%     [P_load_f, P_pv_dc_f, buy_p_market, dt_milp, expand_factor] = ...
%         local_prepare_hourly_forecast(P_load_f_orig, P_pv_dc_f_orig, buy_p_orig, dt_h);
% 
%     N = length(P_load_f);
% 
%     % ---------------------------------------------------------------------
%     % PARAMÉTEREK
%     % ---------------------------------------------------------------------
%     eta_c_path = pars.inv_eta * pars.eta_c * pars.eta_cell;
%     eta_d_path = pars.eta_cell * pars.eta_d * pars.inv_eta;
% 
%     deg_model = build_article_simple_degradation_costs(pars);
%     cost_deg_ch  = deg_model.cost_ch_huf_per_kWh;
%     cost_deg_dis = deg_model.cost_dis_huf_per_kWh;
% 
%     if isfield(pars, 'SoC_initial')
%         SoC_start = pars.SoC_initial;
%     else
%         SoC_start = 0.5;
%     end
% 
%     P_ch_max  = pars.P_chg_max;
%     P_dis_max = pars.P_dis_max;
% 
%     P_contract = contract_state.P_contract_kW;
%     P_month_max_so_far = contract_state.P_month_max_so_far_kW;
% 
%     prev_overrun = max(0, P_month_max_so_far - P_contract);
% 
%     dist_fee = tariff.distribution_energy_rate_huf_per_kWh;
%     trans_fee = tariff.transmission_energy_rate_huf_per_kWh;
%     buy_p_total = buy_p_market + dist_fee + trans_fee;
% 
%     monthly_overrun_cost_per_kW = tariff.penalty_rate_huf_per_kW_year / tariff.months_in_year;
%     within_contract_peak_weight = tariff.within_contract_peak_weight_huf_per_kW_month;
% 
%     P_pv_ac = min(P_pv_dc_f * pars.inv_eta, pars.P_inv_limit_ac);
% 
%     % ---------------------------------------------------------------------
%     % HÁLÓZATI TÖLTÉSHEZ KAPCSOLÓDÓ BÜNTETÉSEK
%     % ---------------------------------------------------------------------
%     qcheap = tariff.grid_charge_price_quantile;
%     cheap_threshold = quantile(buy_p_market, qcheap);
%     cheap_mask = buy_p_market <= cheap_threshold;
% 
%     noncheap_charge_penalty = tariff.noncheap_charge_penalty_huf_per_kWh * (~cheap_mask);
% 
%     % Alapterhelés BESS nélkül AC oldalon
%     base_grid_no_batt = max(P_load_f - P_pv_ac, 0);
% 
%     % Rendelkezésre álló headroom minden időlépésben
%     headroom_vec = max(P_contract - max(P_month_max_so_far, base_grid_no_batt), 0);
% 
%     % Peak-kockázatos hálózati töltés büntetése
%     % 1 kW havi peak-emelés ára ~ monthly_overrun_cost_per_kW
%     % 1 órás MILP esetén ez fajlagosan értelmezhető HUF/kWh-ként.
%     risky_grid_charge_penalty = ...
%         tariff.risky_grid_charge_penalty_multiplier * monthly_overrun_cost_per_kW;
% 
%     % ---------------------------------------------------------------------
%     % SoC minimum
%     % ---------------------------------------------------------------------
%     soc_min_vec = pars.SoC_min * ones(N,1);
% 
%     % ---------------------------------------------------------------------
%     % DÖNTÉSI VÁLTOZÓK
%     % ---------------------------------------------------------------------
%     % iGrid      : teljes hálózati import [kW]
%     % iCh        : teljes töltés [kW]
%     % iDis       : kisütés [kW]
%     % iSoc       : SoC
%     % iMode      : bináris mód
%     % iCurt      : curtailment [kW]
%     % iGridCh    : hálózatból származó töltési teljesítmény [kW]
%     % iRiskCh    : peak-kockázatos hálózati töltés [kW]
%     % iMonthPeak : havi peak jelölt [kW]
%     % iOverInc   : overrun növekmény [kW]
% 
%     n0 = 0;
%     iGrid      = n0 + (1:N); n0 = n0 + N;
%     iCh        = n0 + (1:N); n0 = n0 + N;
%     iDis       = n0 + (1:N); n0 = n0 + N;
%     iSoc       = n0 + (1:N); n0 = n0 + N;
%     iMode      = n0 + (1:N); n0 = n0 + N;
%     iCurt      = n0 + (1:N); n0 = n0 + N;
%     iGridCh    = n0 + (1:N); n0 = n0 + N;
%     iRiskCh    = n0 + (1:N); n0 = n0 + N;
%     iMonthPeak = n0 + 1;     n0 = n0 + 1;
%     iOverInc   = n0 + 1;     n0 = n0 + 1;
%     nVars      = n0;
% 
%     % ---------------------------------------------------------------------
%     % CÉLFÜGGVÉNY
%     % ---------------------------------------------------------------------
%     f = zeros(nVars, 1);
% 
%     % Hálózati import költsége
%     f(iGrid) = buy_p_total * dt_milp;
% 
%     % Degradáció
%     f(iCh)   = cost_deg_ch  * dt_milp;
%     f(iDis)  = cost_deg_dis * dt_milp;
% 
%     % Curtailment
%     f(iCurt) = tariff.curtailment_penalty_huf_per_kWh * dt_milp;
% 
%     % Nem olcsó hálózati töltés büntetése
%     f(iGridCh) = noncheap_charge_penalty * dt_milp;
% 
%     % Peak-kockázatos hálózati töltés büntetése
%     f(iRiskCh) = risky_grid_charge_penalty * dt_milp;
% 
%     % Contract alatti havi peak szint árnyékára
%     f(iMonthPeak) = within_contract_peak_weight;
% 
%     % Contract feletti növekmény
%     f(iOverInc) = monthly_overrun_cost_per_kW;
% 
%     % ---------------------------------------------------------------------
%     % EGYENLŐSÉGI FELTÉTELEK
%     % ---------------------------------------------------------------------
%     Aeq_energy = zeros(N, nVars);
%     beq_energy = P_load_f - P_pv_ac;
% 
%     for t = 1:N
%         Aeq_energy(t, iGrid(t)) =  1;
%         Aeq_energy(t, iDis(t))  =  1;
%         Aeq_energy(t, iCh(t))   = -1;
%         Aeq_energy(t, iCurt(t)) = -1;
%     end
% 
%     Aeq_soc = zeros(N, nVars);
%     beq_soc = zeros(N, 1);
% 
%     Aeq_soc(1, iSoc(1)) = 1;
%     beq_soc(1) = SoC_start;
% 
%     alpha_ch = (eta_c_path * dt_milp) / pars.E_cap_nom;
%     beta_dis = (dt_milp / eta_d_path) / pars.E_cap_nom;
% 
%     for t = 2:N
%         Aeq_soc(t, iSoc(t))   =  1;
%         Aeq_soc(t, iSoc(t-1)) = -1;
%         Aeq_soc(t, iCh(t-1))  = -alpha_ch;
%         Aeq_soc(t, iDis(t-1)) =  beta_dis;
%     end
% 
%     Aeq = [Aeq_energy; Aeq_soc];
%     beq = [beq_energy; beq_soc];
% 
%     % ---------------------------------------------------------------------
%     % EGYENLŐTLENSÉGI FELTÉTELEK
%     % ---------------------------------------------------------------------
%     A = [];
%     b = [];
% 
%     % Töltés / kisütés szétválasztás
%     A_bin = zeros(2*N, nVars);
%     b_bin = zeros(2*N, 1);
% 
%     for t = 1:N
%         A_bin(t, iCh(t))   = 1;
%         A_bin(t, iMode(t)) = -P_ch_max;
% 
%         A_bin(N+t, iDis(t))  = 1;
%         A_bin(N+t, iMode(t)) = P_dis_max;
%         b_bin(N+t) = P_dis_max;
%     end
% 
%     A = [A; A_bin];
%     b = [b; b_bin];
% 
%     % Curtailment korlát
%     A_curt = zeros(N, nVars);
%     b_curt = zeros(N, 1);
%     for t = 1:N
%         A_curt(t, iCurt(t)) = 1;
%         b_curt(t) = P_pv_ac(t);
%     end
%     A = [A; A_curt];
%     b = [b; b_curt];
% 
%     % Havi peak >= minden grid import
%     A_peak = zeros(N, nVars);
%     b_peak = zeros(N, 1);
%     for t = 1:N
%         A_peak(t, iGrid(t)) = 1;
%         A_peak(t, iMonthPeak) = -1;
%     end
%     A = [A; A_peak];
%     b = [b; b_peak];
% 
%     % Overrun növekmény
%     row_over = zeros(1, nVars);
%     row_over(iMonthPeak) = 1;
%     row_over(iOverInc)   = -1;
%     A = [A; row_over];
%     b = [b; P_contract + prev_overrun];
% 
%     % ----------------------------------------------------------
%     % Hálózati töltés szétválasztása
%     % iGridCh >= iCh - PV_surplus
%     % ahol PV_surplus = max(P_pv_ac - P_load_f, 0)
%     % ----------------------------------------------------------
%     pv_surplus = max(P_pv_ac - P_load_f, 0);
% 
%     A_gridch_1 = zeros(N, nVars);
%     b_gridch_1 = pv_surplus;
%     for t = 1:N
%         A_gridch_1(t, iCh(t))     =  1;
%         A_gridch_1(t, iGridCh(t)) = -1;
%     end
%     A = [A; A_gridch_1];
%     b = [b; b_gridch_1];
% 
%     % iGridCh <= iCh
%     A_gridch_2 = zeros(N, nVars);
%     b_gridch_2 = zeros(N, 1);
%     for t = 1:N
%         A_gridch_2(t, iGridCh(t)) =  1;
%         A_gridch_2(t, iCh(t))     = -1;
%     end
%     A = [A; A_gridch_2];
%     b = [b; b_gridch_2];
% 
%     % ----------------------------------------------------------
%     % Peak-kockázatos hálózati töltés:
%     % iRiskCh >= iGridCh - headroom_vec
%     % ----------------------------------------------------------
%     A_risk_1 = zeros(N, nVars);
%     b_risk_1 = headroom_vec;
%     for t = 1:N
%         A_risk_1(t, iGridCh(t)) =  1;
%         A_risk_1(t, iRiskCh(t)) = -1;
%     end
%     A = [A; A_risk_1];
%     b = [b; b_risk_1];
% 
%     % iRiskCh <= iGridCh
%     A_risk_2 = zeros(N, nVars);
%     b_risk_2 = zeros(N, 1);
%     for t = 1:N
%         A_risk_2(t, iRiskCh(t)) =  1;
%         A_risk_2(t, iGridCh(t)) = -1;
%     end
%     A = [A; A_risk_2];
%     b = [b; b_risk_2];
% 
%     % Horizon-végi SoC ne legyen kisebb, mint a kezdő SoC
%     row_terminal_soc = zeros(1, nVars);
%     row_terminal_soc(iSoc(N)) = -1;
%     A = [A; row_terminal_soc];
%     b = [b; -SoC_start];
% 
%     % ---------------------------------------------------------------------
%     % ALSÓ/FELSŐ KORLÁTOK
%     % ---------------------------------------------------------------------
%     lb = zeros(nVars, 1);
%     ub = inf(nVars, 1);
% 
%     lb(iSoc) = soc_min_vec;
%     ub(iSoc) = pars.SoC_max;
% 
%     lb(iMode) = 0;
%     ub(iMode) = 1;
% 
%     lb(iMonthPeak) = P_month_max_so_far;
%     lb(iOverInc)   = 0;
%     lb(iGridCh)    = 0;
%     lb(iRiskCh)    = 0;
% 
%     intcon = iMode;
% 
%     % ---------------------------------------------------------------------
%     % SOLVER
%     % ---------------------------------------------------------------------
%     options = optimoptions('intlinprog', ...
%         'Display', 'off', ...
%         'MaxTime', 15, ...
%         'RelativeGapTolerance', 0.01, ...
%         'IntegerPreprocess', 'advanced', ...
%         'RootLPAlgorithm', 'dual-simplex');
% 
%     [x, fval, exitflag] = intlinprog(f, intcon, A, b, Aeq, beq, lb, ub, options);
% 
%     % ---------------------------------------------------------------------
%     % FALLBACK
%     % ---------------------------------------------------------------------
%     if isempty(x) || exitflag <= 0
%         fallback_grid = max(P_load_f - P_pv_ac, 0);
%         fallback_peak = max(P_month_max_so_far, max(fallback_grid));
%         fallback_over_inc = max(0, max(0, fallback_peak - P_contract) - prev_overrun);
% 
%         plan_hourly = struct();
%         plan_hourly.P_contract = P_contract;
%         plan_hourly.P_month_max_so_far = P_month_max_so_far;
%         plan_hourly.P_month_peak_candidate = fallback_peak;
%         plan_hourly.P_overrun_increment_kW = fallback_over_inc;
% 
%         plan_hourly.trade_buy_mask  = false(1, N);
%         plan_hourly.trade_sell_mask = false(1, N);
% 
%         plan_hourly.P_grid_plan = fallback_grid;
%         plan_hourly.P_ch_plan   = zeros(N, 1);
%         plan_hourly.P_dis_plan  = zeros(N, 1);
%         plan_hourly.P_curt_plan = max(P_pv_ac - P_load_f, 0);
%         plan_hourly.SoC_plan    = SoC_start * ones(N, 1);
%         plan_hourly.P_grid_ch_plan = zeros(N, 1);
%         plan_hourly.P_risky_grid_ch_plan = zeros(N, 1);
% 
%         plan_hourly.exitflag = exitflag;
%         plan_hourly.objective_value = inf;
% 
%         plan_hourly.economics.energy_cost_market = sum(buy_p_market(:) .* plan_hourly.P_grid_plan(:)) * dt_milp;
%         plan_hourly.economics.energy_cost_network = sum((dist_fee + trans_fee) .* plan_hourly.P_grid_plan(:)) * dt_milp;
%         plan_hourly.economics.energy_cost_total = ...
%             plan_hourly.economics.energy_cost_market + plan_hourly.economics.energy_cost_network;
%         plan_hourly.economics.degradation_cost = 0;
%         plan_hourly.economics.overrun_increment_cost = monthly_overrun_cost_per_kW * fallback_over_inc;
%         plan_hourly.economics.net_cost_operational = inf;
% 
%         plan = local_expand_hourly_plan_to_original(plan_hourly, N_orig, expand_factor);
%         return;
%     end
% 
%     % ---------------------------------------------------------------------
%     % MEGOLDÁS KIBONTÁSA
%     % ---------------------------------------------------------------------
%     P_grid = x(iGrid);
%     P_ch   = x(iCh);
%     P_dis  = x(iDis);
%     SoC    = x(iSoc);
%     P_curt = x(iCurt);
%     P_grid_ch = x(iGridCh);
%     P_risky_grid_ch = x(iRiskCh);
%     P_month_peak_candidate = x(iMonthPeak);
%     P_over_inc = x(iOverInc);
% 
%     plan_hourly = struct();
%     plan_hourly.P_contract = P_contract;
%     plan_hourly.P_month_max_so_far = P_month_max_so_far;
%     plan_hourly.P_month_peak_candidate = P_month_peak_candidate;
%     plan_hourly.P_overrun_increment_kW = P_over_inc;
% 
%     plan_hourly.trade_buy_mask  = (P_ch  > 1e-3).';
%     plan_hourly.trade_sell_mask = (P_dis > 1e-3).';
% 
%     plan_hourly.P_grid_plan = P_grid;
%     plan_hourly.P_ch_plan   = P_ch;
%     plan_hourly.P_dis_plan  = P_dis;
%     plan_hourly.P_curt_plan = P_curt;
%     plan_hourly.SoC_plan    = SoC;
%     plan_hourly.P_grid_ch_plan = P_grid_ch;
%     plan_hourly.P_risky_grid_ch_plan = P_risky_grid_ch;
% 
%     plan_hourly.exitflag = exitflag;
%     plan_hourly.objective_value = fval;
% 
%     energy_cost_market  = sum(buy_p_market(:) .* P_grid(:)) * dt_milp;
%     energy_cost_network = sum((dist_fee + trans_fee) .* P_grid(:)) * dt_milp;
%     degradation_cost = ...
%         sum(cost_deg_ch  .* P_ch(:))  * dt_milp + ...
%         sum(cost_deg_dis .* P_dis(:)) * dt_milp;
%     overrun_increment_cost = monthly_overrun_cost_per_kW * P_over_inc;
% 
%     plan_hourly.economics.energy_cost_market = energy_cost_market;
%     plan_hourly.economics.energy_cost_network = energy_cost_network;
%     plan_hourly.economics.energy_cost_total = energy_cost_market + energy_cost_network;
%     plan_hourly.economics.degradation_cost = degradation_cost;
%     plan_hourly.economics.overrun_increment_cost = overrun_increment_cost;
%     plan_hourly.economics.net_cost_operational = ...
%         energy_cost_market + energy_cost_network + degradation_cost + overrun_increment_cost;
% 
%     % ---------------------------------------------------------------------
%     % VISSZAALAKÍTÁS EREDETI FELBONTÁSRA
%     % ---------------------------------------------------------------------
%     plan = local_expand_hourly_plan_to_original(plan_hourly, N_orig, expand_factor);
% end
% 
% 
% % =========================================================================
% % BELSŐ SEGÉDFÜGGVÉNYEK
% % =========================================================================
% function [P_load_h, P_pv_h, buy_h, dt_out, expand_factor] = local_prepare_hourly_forecast(P_load, P_pv, buy_p, dt_in)
% 
%     P_load = P_load(:);
%     P_pv   = P_pv(:);
%     buy_p  = buy_p(:);
% 
%     if dt_in <= 0
%         error('local_prepare_hourly_forecast: dt_in must be positive');
%     end
% 
%     expand_factor_real = 1 / dt_in;
%     expand_factor_round = round(expand_factor_real);
% 
%     can_aggregate = abs(expand_factor_real - expand_factor_round) < 1e-9 && expand_factor_round >= 1;
% 
%     if ~can_aggregate
%         P_load_h = P_load;
%         P_pv_h   = P_pv;
%         buy_h    = buy_p;
%         dt_out   = dt_in;
%         expand_factor = 1;
%         return;
%     end
% 
%     if expand_factor_round == 1
%         P_load_h = P_load;
%         P_pv_h   = P_pv;
%         buy_h    = buy_p;
%         dt_out   = dt_in;
%         expand_factor = 1;
%         return;
%     end
% 
%     N = length(P_load);
%     nBlocks = floor(N / expand_factor_round);
% 
%     if nBlocks < 1
%         P_load_h = P_load;
%         P_pv_h   = P_pv;
%         buy_h    = buy_p;
%         dt_out   = dt_in;
%         expand_factor = 1;
%         return;
%     end
% 
%     N_use = nBlocks * expand_factor_round;
% 
%     P_load_use = P_load(1:N_use);
%     P_pv_use   = P_pv(1:N_use);
%     buy_use    = buy_p(1:N_use);
% 
%     P_load_mat = reshape(P_load_use, expand_factor_round, nBlocks);
%     P_pv_mat   = reshape(P_pv_use,   expand_factor_round, nBlocks);
%     buy_mat    = reshape(buy_use,    expand_factor_round, nBlocks);
% 
%     P_load_h = mean(P_load_mat, 1).';
%     P_pv_h   = mean(P_pv_mat,   1).';
%     buy_h    = mean(buy_mat,    1).';
% 
%     dt_out = 1.0;
%     expand_factor = expand_factor_round;
% end
% 
% 
% function plan_out = local_expand_hourly_plan_to_original(plan_in, N_orig, expand_factor)
% 
%     if expand_factor <= 1
%         plan_out = plan_in;
%         return;
%     end
% 
%     plan_out = plan_in;
% 
%     plan_out.trade_buy_mask  = local_repeat_to_length(logical(plan_in.trade_buy_mask(:)),  N_orig, expand_factor).';
%     plan_out.trade_sell_mask = local_repeat_to_length(logical(plan_in.trade_sell_mask(:)), N_orig, expand_factor).';
% 
%     plan_out.P_grid_plan = local_repeat_to_length(plan_in.P_grid_plan(:), N_orig, expand_factor);
%     plan_out.P_ch_plan   = local_repeat_to_length(plan_in.P_ch_plan(:),   N_orig, expand_factor);
%     plan_out.P_dis_plan  = local_repeat_to_length(plan_in.P_dis_plan(:),  N_orig, expand_factor);
%     plan_out.P_curt_plan = local_repeat_to_length(plan_in.P_curt_plan(:), N_orig, expand_factor);
%     plan_out.SoC_plan    = local_repeat_to_length(plan_in.SoC_plan(:),    N_orig, expand_factor);
% 
%     if isfield(plan_in, 'P_grid_ch_plan')
%         plan_out.P_grid_ch_plan = local_repeat_to_length(plan_in.P_grid_ch_plan(:), N_orig, expand_factor);
%     end
%     if isfield(plan_in, 'P_risky_grid_ch_plan')
%         plan_out.P_risky_grid_ch_plan = local_repeat_to_length(plan_in.P_risky_grid_ch_plan(:), N_orig, expand_factor);
%     end
% end
% 
% 
% function y = local_repeat_to_length(x, N_target, rep_factor)
% 
%     x = x(:);
%     y = repelem(x, rep_factor, 1);
% 
%     if length(y) >= N_target
%         y = y(1:N_target);
%         return;
%     end
% 
%     y = [y; repmat(y(end), N_target - length(y), 1)];
% end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%3.VALTOZAT
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
function plan = ems_day_ahead_planner_milp_contract(P_load_f, P_pv_dc_f, Prices, pars, tariff, dt_h, contract_state, target_step_min)
% EMS_DAY_AHEAD_PLANNER_MILP_CONTRACT
%
% TESZTVERZIO:
% - HARD CAP a halozati importra:
%       grid->load + grid->batt <= P_contract
% - a regi havi peak / overrun logika kikommentelve megmarad
% - a kompatibilitas miatt a korabbi mezok visszaadasra kerulnek,
%   de nullazott formaban, ha ebben a tesztverzioban nem hasznaljuk oket.
%
% Bemenet:
%   P_load_f        : terhelesi forecast [kW]
%   P_pv_dc_f       : PV DC forecast [kW]
%   Prices.buy_huf  : veteli ar [HUF/kWh]
%   pars            : BESS parameterek
%   tariff          : tarifa parameterek
%   dt_h            : eredeti idolepes [h]
%   contract_state  : struct
%       .P_contract_kW
%       .P_month_max_so_far_kW
%       .current_day_of_month
%   target_step_min : opcionális MILP idofelbontas percben
%                     peldaul 5, 10, 15, 30, 60
%                     5 perc tobbszorose kell legyen
%
% Kimenet:
%   plan            : az eredeti idofelbontasra visszanagyitott terv

    % ---------------------------------------------------------------------
    % OPCIONALIS MILP IDOFELBONTAS
    % ---------------------------------------------------------------------
    if nargin < 8 || isempty(target_step_min)
        target_step_min = 60;
    end

    % ---------------------------------------------------------------------
    % HIANYZO TARIFA MEZOK POTLASA
    % ---------------------------------------------------------------------
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
    if ~isfield(tariff, 'contracted_capacity_kW')
        tariff.contracted_capacity_kW = 350;
    end
    if ~isfield(tariff, 'days_in_year')
        tariff.days_in_year = 365;
    end
    if ~isfield(tariff, 'months_in_year')
        tariff.months_in_year = 12;
    end
    if ~isfield(tariff, 'penalty_rate_huf_per_kW_year')
        tariff.penalty_rate_huf_per_kW_year = 4.0 * tariff.annual_contracted_power_fee_huf_per_kW;
    end
    if ~isfield(tariff, 'curtailment_penalty_huf_per_kWh')
        tariff.curtailment_penalty_huf_per_kWh = 0.0;
    end
    if ~isfield(tariff, 'grid_charge_price_quantile')
        tariff.grid_charge_price_quantile = 0.25;
    end
    if ~isfield(tariff, 'noncheap_charge_penalty_huf_per_kWh')
        tariff.noncheap_charge_penalty_huf_per_kWh = 0.0;
    end
    if ~isfield(tariff, 'within_contract_peak_weight_huf_per_kW_month')
        tariff.within_contract_peak_weight_huf_per_kW_month = 0.0;
    end

    % ---------------------------------------------------------------------
    % EREDETI IDOFELBONTAS ELMENTESE
    % ---------------------------------------------------------------------
    P_load_f_orig  = P_load_f(:);
    P_pv_dc_f_orig = P_pv_dc_f(:);
    buy_p_orig     = Prices.buy_huf(:);

    N_orig = length(P_load_f_orig);

    % ---------------------------------------------------------------------
    % AGGREGALAS MEGADOTT MILP IDOFELBONTASRA
    % ---------------------------------------------------------------------
    [P_load_f, P_pv_dc_f, buy_p_market, dt_milp, expand_factor] = ...
        local_prepare_hourly_forecast( ...
            P_load_f_orig, ...
            P_pv_dc_f_orig, ...
            buy_p_orig, ...
            dt_h, ...
            target_step_min);

    N = length(P_load_f);

    % ---------------------------------------------------------------------
    % PARAMETEREK
    % ---------------------------------------------------------------------
    eta_c_path = pars.inv_eta * pars.eta_c * pars.eta_cell;
    eta_d_path = pars.eta_cell * pars.eta_d * pars.inv_eta;

    deg_model = build_article_simple_degradation_costs(pars);
    cost_deg_ch  = deg_model.cost_ch_huf_per_kWh;
    cost_deg_dis = deg_model.cost_dis_huf_per_kWh;

    if isfield(pars, 'SoC_initial')
        SoC_start = pars.SoC_initial;
    else
        SoC_start = 0.5;
    end

    P_ch_max  = pars.P_chg_max;
    P_dis_max = pars.P_dis_max;

    P_contract = contract_state.P_contract_kW;

    % ---------------------------------------------------------------------
    % BIZTONSAGI TARTALEK A LEKOTOTT TELJESITMENYRE
    % ---------------------------------------------------------------------
    % A MILP nem a teljes lekotott teljesitmenyre tervez, hanem annak
    % egy biztonsagi faktorral csokkentett ertekere.
    %
    % Pelda:
    %   P_contract = 480 kW
    %   safety_factor = 0.90
    %   P_grid_hard_cap = 432 kW
    %
    % Igy a kesobbi veszteseg, forecast/actual elteres es topology
    % vegrehajtasi hiba ellen marad tartalek.
    if isfield(contract_state, 'P_contract_safety_factor')
        P_contract_safety_factor = contract_state.P_contract_safety_factor;
    else
        P_contract_safety_factor = 0.90;
    end

    if P_contract_safety_factor <= 0 || P_contract_safety_factor > 1
        error('P_contract_safety_factor must be in the interval (0, 1].');
    end

    P_grid_hard_cap = P_contract_safety_factor * P_contract;

    % ---------------------------------------------------------------------
    % REGI VERZIOHOZ TARTOZO VALTOZOK - KOMPATIBILITAS MIATT MEGTARTVA
    % ---------------------------------------------------------------------
    if isfield(contract_state, 'P_month_max_so_far_kW')
        P_month_max_so_far = contract_state.P_month_max_so_far_kW;
    else
        P_month_max_so_far = 0;
    end

    prev_overrun = 0;

    dist_fee = tariff.distribution_energy_rate_huf_per_kWh;
    trans_fee = tariff.transmission_energy_rate_huf_per_kWh;
    buy_p_total = buy_p_market + dist_fee + trans_fee;

    % Ebben a tesztverzioban nem hasznaljuk oket, de legyenek definialva
    monthly_overrun_cost_per_kW = 0;
    within_contract_peak_weight = 0;
    overrun_cost_per_kW_step = 0;

    P_pv_ac = min(P_pv_dc_f * pars.inv_eta, pars.P_inv_limit_ac);

    soc_min_vec = pars.SoC_min * ones(N,1);

    % ---------------------------------------------------------------------
    % DONTESI VALTOZOK
    % ---------------------------------------------------------------------
    % P_gl    : grid -> load
    % P_gb    : grid -> battery
    % P_pl    : pv   -> load
    % P_pb    : pv   -> battery
    % P_bl    : battery -> load
    % SoC
    % mode    : binaris, 1 = discharge mode, 0 = charge/idle mode
    % Curt
    %
    % A regi verzio:
    % MonthPeak
    % OverInc
    % OverStep
    %
    % Ezeket most nem hasznaljuk aktivan, de kompatibilitas miatt
    % visszaadjuk nullazott mezok formajaban.

    n0 = 0;
    iGload     = n0 + (1:N); n0 = n0 + N;
    iGbatt     = n0 + (1:N); n0 = n0 + N;
    iPVload    = n0 + (1:N); n0 = n0 + N;
    iPVbatt    = n0 + (1:N); n0 = n0 + N;
    iBload     = n0 + (1:N); n0 = n0 + N;
    iSoc       = n0 + (1:N); n0 = n0 + N;
    iMode      = n0 + (1:N); n0 = n0 + N;
    iCurt      = n0 + (1:N); n0 = n0 + N;

    % ---------------------------------------------------------------------
    % REGI, NEM HASZNALT RESZEK - KIKOMMENTELVE
    % ---------------------------------------------------------------------
    % iMonthPeak = n0 + 1;     n0 = n0 + 1;
    % iOverInc   = n0 + 1;     n0 = n0 + 1;
    % iOverStep  = n0 + (1:N); n0 = n0 + N;

    nVars = n0;

    % ---------------------------------------------------------------------
    % CELFUGGVENY
    % ---------------------------------------------------------------------
    f = zeros(nVars, 1);

    % Halozati energia
    f(iGload) = buy_p_total * dt_milp;
    f(iGbatt) = buy_p_total * dt_milp;

    % Degradacio
    f(iGbatt)  = f(iGbatt)  + cost_deg_ch  * dt_milp;
    f(iPVbatt) = f(iPVbatt) + cost_deg_ch  * dt_milp;
    f(iBload)  = f(iBload)  + cost_deg_dis * dt_milp;

    % Curtailment
    f(iCurt) = tariff.curtailment_penalty_huf_per_kWh * dt_milp;

    % ---------------------------------------------------------------------
    % REGI, NEM HASZNALT RESZEK - KIKOMMENTELVE
    % ---------------------------------------------------------------------
    % f(iMonthPeak) = within_contract_peak_weight;
    % f(iOverInc)   = monthly_overrun_cost_per_kW;
    % f(iOverStep)  = overrun_cost_per_kW_step;

    % ---------------------------------------------------------------------
    % EGYENLOSEGI FELTETELEK
    % ---------------------------------------------------------------------
    % Load ellatas:
    % grid->load + pv->load + batt->load = load
    Aeq_load = zeros(N, nVars);
    beq_load = P_load_f;

    for t = 1:N
        Aeq_load(t, iGload(t))  = 1;
        Aeq_load(t, iPVload(t)) = 1;
        Aeq_load(t, iBload(t))  = 1;
    end

    % PV szetosztas:
    % pv->load + pv->batt + curt = pv_ac
    Aeq_pv = zeros(N, nVars);
    beq_pv = P_pv_ac;

    for t = 1:N
        Aeq_pv(t, iPVload(t)) = 1;
        Aeq_pv(t, iPVbatt(t)) = 1;
        Aeq_pv(t, iCurt(t))   = 1;
    end

    % SoC dinamika
    Aeq_soc = zeros(N, nVars);
    beq_soc = zeros(N, 1);

    Aeq_soc(1, iSoc(1)) = 1;
    beq_soc(1) = SoC_start;

    alpha_ch = (eta_c_path * dt_milp) / pars.E_cap_nom;
    beta_dis = (dt_milp / eta_d_path) / pars.E_cap_nom;

    for t = 2:N
        Aeq_soc(t, iSoc(t))       =  1;
        Aeq_soc(t, iSoc(t-1))     = -1;
        Aeq_soc(t, iGbatt(t-1))   = -alpha_ch;
        Aeq_soc(t, iPVbatt(t-1))  = -alpha_ch;
        Aeq_soc(t, iBload(t-1))   =  beta_dis;
    end

    Aeq = [Aeq_load; Aeq_pv; Aeq_soc];
    beq = [beq_load; beq_pv; beq_soc];

    % ---------------------------------------------------------------------
    % EGYENLOTLENSEGI FELTETELEK
    % ---------------------------------------------------------------------
    A = [];
    b = [];

    % Toltes / kisutes mod
    % grid->batt + pv->batt <= P_ch_max * (1 - mode)
    A_ch = zeros(N, nVars);
    b_ch = P_ch_max * ones(N,1);

    for t = 1:N
        A_ch(t, iGbatt(t)) = 1;
        A_ch(t, iPVbatt(t)) = 1;
        A_ch(t, iMode(t)) = P_ch_max;
    end

    A = [A; A_ch];
    b = [b; b_ch];

    % batt->load <= P_dis_max * mode
    A_dis = zeros(N, nVars);
    b_dis = zeros(N,1);

    for t = 1:N
        A_dis(t, iBload(t)) = 1;
        A_dis(t, iMode(t))  = -P_dis_max;
    end

    A = [A; A_dis];
    b = [b; b_dis];

    % ---------------------------------------------------------------------
    % UJ AKTIV TESZTLOGIKA:
    % HARD CAP a teljes halozati importra
    % grid->load + grid->batt <= P_contract
    % ---------------------------------------------------------------------
    A_grid_cap = zeros(N, nVars);
    % b_grid_cap = P_contract * ones(N,1);
    b_grid_cap = P_grid_hard_cap * ones(N,1);

    for t = 1:N
        A_grid_cap(t, iGload(t)) = 1;
        A_grid_cap(t, iGbatt(t)) = 1;
    end

    A = [A; A_grid_cap];
    b = [b; b_grid_cap];

    % ---------------------------------------------------------------------
    % REGI, NEM HASZNALT RESZEK - KIKOMMENTELVE
    % ---------------------------------------------------------------------
    % % Havi peak >= teljes halozati import
    % A_peak = zeros(N, nVars);
    % b_peak = zeros(N, 1);
    % for t = 1:N
    %     A_peak(t, iGload(t))     = 1;
    %     A_peak(t, iGbatt(t))     = 1;
    %     A_peak(t, iMonthPeak)    = -1;
    % end
    % A = [A; A_peak];
    % b = [b; b_peak];
    %
    % % Overrun novekmeny:
    % row_over = zeros(1, nVars);
    % row_over(iMonthPeak) = 1;
    % row_over(iOverInc)   = -1;
    % A = [A; row_over];
    % b = [b; P_contract + prev_overrun];
    %
    % % Idolepesenkenti overrun buntetes
    % A_over_step = zeros(N, nVars);
    % b_over_step = P_contract * ones(N,1);
    % for t = 1:N
    %     A_over_step(t, iGload(t))    =  1;
    %     A_over_step(t, iGbatt(t))    =  1;
    %     A_over_step(t, iOverStep(t)) = -1;
    % end
    % A = [A; A_over_step];
    % b = [b; b_over_step];

    % Horizon vegen SoC ne legyen kisebb mint indulaskor
    row_terminal_soc = zeros(1, nVars);
    row_terminal_soc(iSoc(N)) = -1;

    A = [A; row_terminal_soc];
    b = [b; -SoC_start];

    % ---------------------------------------------------------------------
    % ALSO/FELSO KORLATOK
    % ---------------------------------------------------------------------
    lb = zeros(nVars, 1);
    ub = inf(nVars, 1);

    lb(iSoc) = soc_min_vec;
    ub(iSoc) = pars.SoC_max;

    lb(iMode) = 0;
    ub(iMode) = 1;

    % ---------------------------------------------------------------------
    % REGI, NEM HASZNALT RESZEK - KIKOMMENTELVE
    % ---------------------------------------------------------------------
    % lb(iMonthPeak) = P_month_max_so_far;
    % lb(iOverInc)   = 0;
    % lb(iOverStep)  = 0;

    intcon = iMode;

    % ---------------------------------------------------------------------
    % SOLVER
    % ---------------------------------------------------------------------
    options = optimoptions('intlinprog', ...
        'Display', 'off', ...
        'MaxTime', 15, ...
        'RelativeGapTolerance', 0.01, ...
        'IntegerPreprocess', 'advanced', ...
        'RootLPAlgorithm', 'dual-simplex');

    [x, fval, exitflag] = intlinprog(f, intcon, A, b, Aeq, beq, lb, ub, options);

    % ---------------------------------------------------------------------
    % FALLBACK
    % ---------------------------------------------------------------------
    if isempty(x) || exitflag <= 0
        fallback_grid = max(P_load_f - P_pv_ac, 0);

        plan_hourly = struct();
        plan_hourly.P_contract = P_contract;
        plan_hourly.P_month_max_so_far = P_month_max_so_far;

        % Kompatibilitasi mezok
        plan_hourly.P_month_peak_candidate = max(fallback_grid);
        plan_hourly.P_overrun_increment_kW = 0;
        plan_hourly.P_over_step_plan = zeros(N,1);

        plan_hourly.trade_buy_mask  = false(1, N);
        plan_hourly.trade_sell_mask = false(1, N);

        plan_hourly.P_grid_plan = fallback_grid;
        plan_hourly.P_ch_plan   = zeros(N, 1);
        plan_hourly.P_dis_plan  = zeros(N, 1);
        plan_hourly.P_curt_plan = max(P_pv_ac - P_load_f, 0);
        plan_hourly.SoC_plan    = SoC_start * ones(N, 1);

        plan_hourly.P_gload_plan  = fallback_grid;
        plan_hourly.P_gbatt_plan  = zeros(N,1);
        plan_hourly.P_pvload_plan = min(P_pv_ac, P_load_f);
        plan_hourly.P_pvbatt_plan = zeros(N,1);
        plan_hourly.P_bload_plan  = zeros(N,1);

        plan_hourly.exitflag = exitflag;
        plan_hourly.objective_value = inf;

        plan_hourly.economics.energy_cost_market = sum(buy_p_market(:) .* plan_hourly.P_grid_plan(:)) * dt_milp;
        plan_hourly.economics.energy_cost_network = sum((dist_fee + trans_fee) .* plan_hourly.P_grid_plan(:)) * dt_milp;
        plan_hourly.economics.energy_cost_total = ...
            plan_hourly.economics.energy_cost_market + plan_hourly.economics.energy_cost_network;
        plan_hourly.economics.degradation_cost = 0;
        plan_hourly.economics.overrun_increment_cost = 0;
        plan_hourly.economics.net_cost_operational = inf;

        plan = local_expand_hourly_plan_to_original(plan_hourly, N_orig, expand_factor);
        return;
    end

    % ---------------------------------------------------------------------
    % MEGOLDAS KIBONTASA
    % ---------------------------------------------------------------------
    P_gload  = x(iGload);
    P_gbatt  = x(iGbatt);
    P_pvload = x(iPVload);
    P_pvbatt = x(iPVbatt);
    P_bload  = x(iBload);
    SoC      = x(iSoc);
    P_curt   = x(iCurt);

    P_grid_total   = P_gload + P_gbatt;
    P_charge_total = P_gbatt + P_pvbatt;
    P_dis_total    = P_bload;

    plan_hourly = struct();
    plan_hourly.P_contract = P_contract;
    plan_hourly.P_month_max_so_far = P_month_max_so_far;

    % Kompatibilitasi mezok
    plan_hourly.P_month_peak_candidate = max(P_grid_total);
    plan_hourly.P_overrun_increment_kW = 0;
    plan_hourly.P_over_step_plan = zeros(N,1);

    plan_hourly.trade_buy_mask  = (P_gbatt > 1e-3).';
    plan_hourly.trade_sell_mask = (P_bload > 1e-3).';

    plan_hourly.P_grid_plan = P_grid_total;
    plan_hourly.P_ch_plan   = P_charge_total;
    plan_hourly.P_dis_plan  = P_dis_total;
    plan_hourly.P_curt_plan = P_curt;
    plan_hourly.SoC_plan    = SoC;

    plan_hourly.P_gload_plan  = P_gload;
    plan_hourly.P_gbatt_plan  = P_gbatt;
    plan_hourly.P_pvload_plan = P_pvload;
    plan_hourly.P_pvbatt_plan = P_pvbatt;
    plan_hourly.P_bload_plan  = P_bload;

    plan_hourly.exitflag = exitflag;
    plan_hourly.objective_value = fval;

    energy_cost_market  = sum(buy_p_market(:) .* P_grid_total(:)) * dt_milp;
    energy_cost_network = sum((dist_fee + trans_fee) .* P_grid_total(:)) * dt_milp;
    degradation_cost    = ...
        sum(cost_deg_ch  .* P_charge_total(:)) * dt_milp + ...
        sum(cost_deg_dis .* P_dis_total(:))    * dt_milp;
    overrun_increment_cost = 0;

    plan_hourly.economics.energy_cost_market = energy_cost_market;
    plan_hourly.economics.energy_cost_network = energy_cost_network;
    plan_hourly.economics.energy_cost_total = energy_cost_market + energy_cost_network;
    plan_hourly.economics.degradation_cost = degradation_cost;
    plan_hourly.economics.overrun_increment_cost = overrun_increment_cost;
    plan_hourly.economics.net_cost_operational = ...
        energy_cost_market + energy_cost_network + degradation_cost + overrun_increment_cost;

    % ---------------------------------------------------------------------
    % VISSZAALAKITAS EREDETI FELBONTASRA
    % ---------------------------------------------------------------------
    plan = local_expand_hourly_plan_to_original(plan_hourly, N_orig, expand_factor);
end


% =========================================================================
% BELSO SEGEDFUGGVENYEK
% =========================================================================
% function [P_load_h, P_pv_h, buy_h, dt_out, expand_factor] = local_prepare_hourly_forecast(P_load, P_pv, buy_p, dt_in, target_step_min)
% % LOCAL_PREPARE_HOURLY_FORECAST
% %
% % Az eredeti idosorokat megadott perces MILP felbontasra aggregalja.
% %
% % Pelda:
% %   dt_in = 1/12 es target_step_min = 15
% %   Ekkor az eredeti 5 perces adatokbol 15 perces adatok keszulnek,
% %   vagyis expand_factor = 3.
% %
% % Fontos:
% %   - target_step_min 5 perc tobbszorose kell legyen
% %   - target_step_min nem lehet kisebb, mint az eredeti idolepes
% %   - target_step_min az eredeti idolepes egesz szamu tobbszorose kell legyen
% 
%     P_load = P_load(:);
%     P_pv   = P_pv(:);
%     buy_p  = buy_p(:);
% 
%     if nargin < 5 || isempty(target_step_min)
%         target_step_min = 60;
%     end
% 
%     if dt_in <= 0
%         error('local_prepare_hourly_forecast: dt_in must be positive');
%     end
% 
%     if target_step_min <= 0
%         error('local_prepare_hourly_forecast: target_step_min must be positive');
%     end
% 
%     if abs(target_step_min / 5 - round(target_step_min / 5)) > 1e-9
%         error('local_prepare_hourly_forecast: target_step_min must be a multiple of 5 minutes');
%     end
% 
%     input_step_min = dt_in * 60;
% 
%     if abs(input_step_min / 5 - round(input_step_min / 5)) > 1e-9
%         error('local_prepare_hourly_forecast: input time step must be a multiple of 5 minutes');
%     end
% 
%     if target_step_min < input_step_min
%         error('local_prepare_hourly_forecast: target_step_min cannot be smaller than the input time step');
%     end
% 
%     expand_factor_real = target_step_min / input_step_min;
%     expand_factor = round(expand_factor_real);
% 
%     can_aggregate = ...
%         abs(expand_factor_real - expand_factor) < 1e-9 && ...
%         expand_factor >= 1;
% 
%     if ~can_aggregate
%         error('local_prepare_hourly_forecast: target_step_min must be an integer multiple of the input time step');
%     end
% 
%     if expand_factor == 1
%         P_load_h = P_load;
%         P_pv_h   = P_pv;
%         buy_h    = buy_p;
%         dt_out   = dt_in;
%         return;
%     end
% 
%     N = min([length(P_load), length(P_pv), length(buy_p)]);
%     P_load = P_load(1:N);
%     P_pv   = P_pv(1:N);
%     buy_p  = buy_p(1:N);
% 
%     nBlocks = floor(N / expand_factor);
% 
%     if nBlocks < 1
%         P_load_h = P_load;
%         P_pv_h   = P_pv;
%         buy_h    = buy_p;
%         dt_out   = dt_in;
%         expand_factor = 1;
%         return;
%     end
% 
%     N_use = nBlocks * expand_factor;
% 
%     P_load_use = P_load(1:N_use);
%     P_pv_use   = P_pv(1:N_use);
%     buy_use    = buy_p(1:N_use);
% 
%     P_load_mat = reshape(P_load_use, expand_factor, nBlocks);
%     P_pv_mat   = reshape(P_pv_use,   expand_factor, nBlocks);
%     buy_mat    = reshape(buy_use,    expand_factor, nBlocks);
% 
%     P_load_h = mean(P_load_mat, 1).';
%     P_pv_h   = mean(P_pv_mat,   1).';
%     buy_h    = mean(buy_mat,    1).';
% 
%     dt_out = target_step_min / 60;
% end

function [P_load_h, P_pv_h, buy_h, dt_out, expand_factor] = local_prepare_hourly_forecast(P_load, P_pv, buy_p, dt_in, target_step_min)
% LOCAL_PREPARE_HOURLY_FORECAST
%
% Az eredeti idosorokat megadott perces MILP felbontasra aggregalja.
%
% Konzervativ aggregalas peak shaving celra:
%   - load esetén a blokk maximumát vesszük;
%   - PV esetén a blokk minimumát vesszük;
%   - ár esetén a blokk átlagát vesszük.
%
% Pelda:
%   dt_in = 1/12 es target_step_min = 15
%   Ekkor az eredeti 5 perces adatokbol 15 perces adatok keszulnek,
%   vagyis expand_factor = 3.
%
% Ha egy 15 perces blokkban a load:
%   [420, 510, 460] kW
% akkor az aggregalt load:
%   510 kW
%
% Ha ugyanabban a blokkban a PV:
%   [180, 150, 170] kW
% akkor az aggregalt PV:
%   150 kW
%
% Fontos:
%   - target_step_min 5 perc tobbszorose kell legyen
%   - target_step_min nem lehet kisebb, mint az eredeti idolepes
%   - target_step_min az eredeti idolepes egesz szamu tobbszorose kell legyen

    P_load = P_load(:);
    P_pv   = P_pv(:);
    buy_p  = buy_p(:);

    if nargin < 5 || isempty(target_step_min)
        target_step_min = 60;
    end

    if dt_in <= 0
        error('local_prepare_hourly_forecast: dt_in must be positive');
    end

    if target_step_min <= 0
        error('local_prepare_hourly_forecast: target_step_min must be positive');
    end

    if abs(target_step_min / 5 - round(target_step_min / 5)) > 1e-9
        error('local_prepare_hourly_forecast: target_step_min must be a multiple of 5 minutes');
    end

    input_step_min = dt_in * 60;

    if abs(input_step_min / 5 - round(input_step_min / 5)) > 1e-9
        error('local_prepare_hourly_forecast: input time step must be a multiple of 5 minutes');
    end

    if target_step_min < input_step_min
        error('local_prepare_hourly_forecast: target_step_min cannot be smaller than the input time step');
    end

    expand_factor_real = target_step_min / input_step_min;
    expand_factor = round(expand_factor_real);

    can_aggregate = ...
        abs(expand_factor_real - expand_factor) < 1e-9 && ...
        expand_factor >= 1;

    if ~can_aggregate
        error('local_prepare_hourly_forecast: target_step_min must be an integer multiple of the input time step');
    end

    if expand_factor == 1
        P_load_h = P_load;
        P_pv_h   = P_pv;
        buy_h    = buy_p;
        dt_out   = dt_in;
        return;
    end

    N = min([length(P_load), length(P_pv), length(buy_p)]);
    P_load = P_load(1:N);
    P_pv   = P_pv(1:N);
    buy_p  = buy_p(1:N);

    nBlocks = floor(N / expand_factor);

    if nBlocks < 1
        P_load_h = P_load;
        P_pv_h   = P_pv;
        buy_h    = buy_p;
        dt_out   = dt_in;
        expand_factor = 1;
        return;
    end

    N_use = nBlocks * expand_factor;

    P_load_use = P_load(1:N_use);
    P_pv_use   = P_pv(1:N_use);
    buy_use    = buy_p(1:N_use);

    P_load_mat = reshape(P_load_use, expand_factor, nBlocks);
    P_pv_mat   = reshape(P_pv_use,   expand_factor, nBlocks);
    buy_mat    = reshape(buy_use,    expand_factor, nBlocks);

    % Konzervativ aggregalas:
    % load: legnagyobb ertek
    % PV:   legkisebb ertek
    % ar:   atlag
    P_load_h = max(P_load_mat, [], 1).';
    P_pv_h   = min(P_pv_mat,   [], 1).';
    buy_h    = mean(buy_mat,      1).';

    dt_out = target_step_min / 60;
end


function plan_out = local_expand_hourly_plan_to_original(plan_in, N_orig, expand_factor)
% LOCAL_EXPAND_HOURLY_PLAN_TO_ORIGINAL
%
% Az aggregalt MILP-tervet visszaterjeszti az eredeti idofelbontasra.
%
% Pelda:
%   eredeti adat: 5 perc
%   MILP adat:    15 perc
%   expand_factor = 3
%
% Ekkor minden 15 perces MILP dontes 3 darab 5 perces lepesre lesz
% megismetelve.

    if expand_factor <= 1
        plan_out = plan_in;
        return;
    end

    plan_out = plan_in;

    plan_out.trade_buy_mask  = local_repeat_to_length(logical(plan_in.trade_buy_mask(:)),  N_orig, expand_factor).';
    plan_out.trade_sell_mask = local_repeat_to_length(logical(plan_in.trade_sell_mask(:)), N_orig, expand_factor).';

    plan_out.P_grid_plan = local_repeat_to_length(plan_in.P_grid_plan(:), N_orig, expand_factor);
    plan_out.P_ch_plan   = local_repeat_to_length(plan_in.P_ch_plan(:),   N_orig, expand_factor);
    plan_out.P_dis_plan  = local_repeat_to_length(plan_in.P_dis_plan(:),  N_orig, expand_factor);
    plan_out.P_curt_plan = local_repeat_to_length(plan_in.P_curt_plan(:), N_orig, expand_factor);
    plan_out.SoC_plan    = local_repeat_to_length(plan_in.SoC_plan(:),    N_orig, expand_factor);

    if isfield(plan_in, 'P_gload_plan')
        plan_out.P_gload_plan = local_repeat_to_length(plan_in.P_gload_plan(:), N_orig, expand_factor);
    end
    if isfield(plan_in, 'P_gbatt_plan')
        plan_out.P_gbatt_plan = local_repeat_to_length(plan_in.P_gbatt_plan(:), N_orig, expand_factor);
    end
    if isfield(plan_in, 'P_pvload_plan')
        plan_out.P_pvload_plan = local_repeat_to_length(plan_in.P_pvload_plan(:), N_orig, expand_factor);
    end
    if isfield(plan_in, 'P_pvbatt_plan')
        plan_out.P_pvbatt_plan = local_repeat_to_length(plan_in.P_pvbatt_plan(:), N_orig, expand_factor);
    end
    if isfield(plan_in, 'P_bload_plan')
        plan_out.P_bload_plan = local_repeat_to_length(plan_in.P_bload_plan(:), N_orig, expand_factor);
    end
    if isfield(plan_in, 'P_over_step_plan')
        plan_out.P_over_step_plan = local_repeat_to_length(plan_in.P_over_step_plan(:), N_orig, expand_factor);
    end
end


function y = local_repeat_to_length(x, N_target, rep_factor)

    x = x(:);
    y = repelem(x, rep_factor, 1);

    if length(y) >= N_target
        y = y(1:N_target);
        return;
    end

    y = [y; repmat(y(end), N_target - length(y), 1)];
end
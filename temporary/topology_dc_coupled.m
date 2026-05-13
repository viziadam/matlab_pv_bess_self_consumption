function [step_res, state_bess] = topology_dc_coupled(P_bess_dc_req_kW, P_pv_dc_kW, P_load_kW, Prices, pars, state_bess, dt_h)
    % TOPOLOGY_DC_COUPLED - DC-csatolt rendszer fizikai kábelezése
    % Ez a modul szimulálja a hardverek tényleges viselkedését, veszteségeit
    % és a DC/AC sín áramlásait az EMS kérése alapján.

    N = length(P_pv_dc_kW);

    % --- 1. KOMPONENS: DC/DC Konverter (Lefelé az akkuhoz) ---
    % Az EMS kérését [kW] átküldjük a konverteren.
    % A konverterből kijövő, ténylegesen a cellákra jutó teljesítményt [W]-ban kapjuk.
    [P_pack_req_W, ~] = hw_dcdc_converter(P_bess_dc_req_kW * 1000, pars.P_chg_max * 1000, pars.eta_c, pars.eta_d);

    % --- 2. KOMPONENS: Akkumulátor Csomag (BESS Pack) ---
    % Meghívjuk a te részletes (Bolun Xu) cellamodeledet
    pack_params = struct('T_vec', 25 * ones(1, N));
    if isfield(pars, 'T_vec'), pack_params.T_vec = pars.T_vec; end

    [pack_out, state_bess] = bess_pack_model(P_pack_req_W, 'run', pack_params, dt_h, state_bess);

    % Kiszámoljuk a ténylegesen leadott/felvett akku teljesítményt [W]-ban
    P_pack_actual_W = (pack_out.E_discharged - pack_out.E_stored) ./ dt_h;

    % --- 3. KOMPONENS: DC/DC Konverter (Felfelé a DC Sínre) ---
    % Visszafejtjük, hogy a valós akku válasz mit jelent a DC sínen terhelésként.
    % Mivel lentről (Akku) megyünk felfelé (DC Sín), az inverz hatásfokokkal hívjuk:
    [P_bess_dc_actual_W, P_loss_dcdc_W] = hw_dcdc_converter(P_pack_actual_W, pars.P_chg_max * 1000, 1/pars.eta_c, 1/pars.eta_d);
    P_bess_dc_actual_kW = P_bess_dc_actual_W / 1000;

    % --- 4. CSOMÓPONT: A Közös DC Sín (DC Bus) ---
    % Itt találkozik a nyers napelem és a tényleges akku egyenáram
    P_bus_dc_actual_kW = P_pv_dc_kW + P_bess_dc_actual_kW;

    % --- 5. KOMPONENS: Fő Inverter (DC/AC) ---
    % A DC sínt rákötjük a hálózatra. Itt történik a fizikai Clipping!
    [P_inv_ac_kW, P_loss_inv_kW, P_clip_kW] = hw_dcac_inverter(P_bus_dc_actual_kW, pars.P_inv_limit_ac, pars.inv_eta);

    % --- 6. CSOMÓPONT: Az AC Hálózat Mérlege ---
    % --- 6. CSOMÓPONT: Az AC Hálózat Mérlege ---
    % A gyár fogyasztását levonjuk abból, amit az inverter AC oldalon betáplál
    P_grid_final_kW = P_load_kW - P_inv_ac_kW;
    
    % --- BASELINE (AKKU NÉLKÜLI) FIZIKA ---
    % Mi történt volna, ha a PV közvetlenül az inverterre megy BESS nélkül?
    P_inv_ac_base = min(P_pv_dc_kW .* pars.inv_eta, pars.P_inv_limit_ac);
    P_grid_base_kW = P_load_kW - P_inv_ac_base;

    % =====================================================================
    % --- 7. KÖNYVELÉS (CSAK NYERS, ALAPVETŐ ADATOK) ---
    % =====================================================================
    step_res = struct();
    
    % 7.1. Energiák és Fogyasztás (Aktuális BESS állapot szerint)
    step_res.E_pv_dc        = P_pv_dc_kW .* dt_h;
    step_res.E_load         = P_load_kW .* dt_h;
    step_res.E_grid_import  = max(P_grid_final_kW, 0) .* dt_h;
    step_res.E_grid_export  = abs(min(P_grid_final_kW, 0)) .* dt_h;
    
    % 7.2. Pénzügyek (Aktuális BESS állapot szerint)
    step_res.Cost_import_HUF = step_res.E_grid_import .* Prices.buy_huf;
    step_res.Rev_export_HUF  = step_res.E_grid_export .* Prices.sell_huf;
    
    % 7.3. Akku és DC sín adatok (Wh-ból kWh-ba váltva)
    step_res.E_stored       = pack_out.E_stored / 1000;
    step_res.E_discharged   = pack_out.E_discharged / 1000;
    step_res.E_bess_dc      = P_bess_dc_actual_kW .* dt_h;
    
    % 7.4. Részletes Veszteség-analitika
    step_res.E_loss_joule   = pack_out.E_loss_joule / 1000;
    step_res.E_loss_dcdc    = (P_loss_dcdc_W / 1000) .* dt_h;
    step_res.E_loss_inv     = P_loss_inv_kW .* dt_h;
    step_res.E_clip_inv     = P_clip_kW .* dt_h; % Tényleges levágás BESS-szel
    
    % 7.5. Referencia (Baseline) Adatok - Ebből számoljuk a megtakarítást!
    step_res.E_clip_base          = max((P_pv_dc_kW .* pars.inv_eta) - pars.P_inv_limit_ac, 0) .* dt_h;
    step_res.E_grid_import_base   = max(P_grid_base_kW, 0) .* dt_h;
    step_res.Cost_import_base_HUF = step_res.E_grid_import_base .* Prices.buy_huf;

    % 7.6. Belső Állapotok (Nap végi profilokhoz / mentéshez)
    step_res.SOC_end        = pack_out.SOC(end);
    step_res.SOH_end        = pack_out.SOH(end);
    step_res.T_cell_max     = max(pack_out.T_cell);
end
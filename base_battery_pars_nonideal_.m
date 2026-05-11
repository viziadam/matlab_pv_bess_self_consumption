function pars = base_battery_pars_nonideal_(E_cap_nom, Pmax)

    pars = struct();

    pars.E_cap_nom        = E_cap_nom;
    pars.P_rated          = Pmax;
    pars.C_chg_abs_max    = Pmax / max(E_cap_nom, eps);
    pars.C_dis_abs_max    = pars.C_chg_abs_max;
    pars.P_chg_max        = Pmax;
    pars.P_dis_max        = Pmax;

    pars.SoC_min          = 0.20;
    pars.SoC_max          = 0.80;
    pars.SoC_init         = 0.50;

    pars.eta_c            = 0.975;
    pars.eta_d            = 0.975;
    pars.k_ohm            = 0.020;

    pars.self_dis_per_h   = 2e-5;
    pars.cap_floor_frac   = 0.70;

    pars.inv_eta          = 0.97;
    pars.eta_c            = 0.98;
    pars.eta_d            = 0.98;

    pars.eta_cell         = 0.985;
    pars.eta_cell_min     = 0.90;

    pars.k_eta_C2         = 0.02;
    pars.k_eta_soc        = 0.02;
    pars.soc_ref          = 0.5;

    pars.R_growth_time_k  = 0.50;
    pars.R_growth_cap_k   = 1.00;

    C_abs                 = Pmax / max(E_cap_nom, eps);
    C_ref                 = min(C_abs, 0.5);
    pars.C_rec_chg        = C_ref;
    pars.C_rec_dis        = C_ref;

    %for degradation costs:
    pars.battery_replacement_cost_huf_per_kWh = 90000;   % példa
    pars.cap_floor_frac = 0.80;

    pars.article_a_soh_per_fec = 3.18e-7;
end
function deg_model = build_article_simple_degradation_costs(pars)
% BUILD_ARTICLE_SIMPLE_DEGRADATION_COSTS
%
% A korábban átnézett MILP-cikk egyszerűsített degradációs költségmodellje.
%
% A modell lényege:
%   DeltaSOH = |a_SOH| * DeltaFEC
%   DeltaFEC = (P / E_nom) * dt / 2
%   C_deg    = c_ag * DeltaSOH
%
% ahol:
%   c_ag = (c_bat * E_nom) / (1 - k_EOL)
%
% Ebből az E_nom kiesik, így egy egyszerű HUF/kWh throughput alapú
% költség adódik:
%
%   c_deg_throughput_huf_per_kWh =
%       c_bat_huf_per_kWh * |a_SOH| / (2 * (1 - k_EOL))
%
% Ez a MILP számára közvetlenül használható lineáris költség.
%
% Bemenet:
%   pars.battery_replacement_cost_huf_per_kWh   [HUF/kWh]  kötelező
%   pars.cap_floor_frac                         [-]        opcionális, default 0.80
%   pars.article_a_soh_per_fec                 [SOH/FEC]  opcionális
%
% Kimenet:
%   deg_model.cost_ch_huf_per_kWh
%   deg_model.cost_dis_huf_per_kWh
%   deg_model.c_ag_huf_per_soh
%   deg_model.a_soh_abs_per_fec
%   deg_model.k_eol
%   deg_model.note

    if ~isfield(pars, 'battery_replacement_cost_huf_per_kWh')
        error(['build_article_simple_degradation_costs: hianyzik a ', ...
               'pars.battery_replacement_cost_huf_per_kWh parameter']);
    end

    if ~isfield(pars, 'cap_floor_frac')
        pars.cap_floor_frac = 0.80;
    end

    % A cikkből:
    % a_SOH = -3.18e-7 [DeltaSOH / FEC]
    % MILP költséghez az abszolút értéket használjuk
    if ~isfield(pars, 'article_a_soh_per_fec')
        pars.article_a_soh_per_fec = 3.18e-7;
    end

    c_bat = pars.battery_replacement_cost_huf_per_kWh;   % [HUF/kWh]
    k_eol = pars.cap_floor_frac;                         % pl. 0.80
    a_soh = abs(pars.article_a_soh_per_fec);             % [SOH/FEC]

    usable_soh_window = max(1 - k_eol, 1e-12);

    % Egységnyi SOH-veszteség ára [HUF / 1 SOH] egy 1 kWh-s akku esetén:
    % c_ag_per_kWhcap = c_bat / (1-k_eol)
    c_ag_per_kWhcap_huf_per_soh = c_bat / usable_soh_window;

    % Egyszerű throughput alapú degradációs költség:
    % c_deg = c_bat * a_soh / (2 * (1-k_eol))
    c_deg_throughput_huf_per_kWh = c_bat * a_soh / (2 * usable_soh_window);

    deg_model = struct();
    deg_model.cost_ch_huf_per_kWh  = c_deg_throughput_huf_per_kWh;
    deg_model.cost_dis_huf_per_kWh = c_deg_throughput_huf_per_kWh;
    deg_model.c_ag_huf_per_soh     = c_ag_per_kWhcap_huf_per_soh;
    deg_model.a_soh_abs_per_fec    = a_soh;
    deg_model.k_eol                = k_eol;
    deg_model.note = ['Egyszerusitett cikk-alapu MILP degradacios koltseg: ', ...
                      'linearis throughput modell'];
end
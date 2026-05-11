function state = init_bess_state_for_candidate(design, cfg, dt_h)
% INIT_BESS_STATE_FOR_CANDIDATE
%
% BESS allapot inicializalasa egy candidate futtatasa elott.
%
% Bemenet:
%   design.E_BESS_kWh
%   design.P_BESS_kW
%   cfg.bess.SoC_initial
%   dt_h
%
% Kimenet:
%   state.SoC
%   state.bess_state
%   state.pack_info

    if isfield(cfg, 'bess') && isfield(cfg.bess, 'SoC_initial')
        SoC_initial = cfg.bess.SoC_initial;
    else
        SoC_initial = 0.5;
    end

    pack_params = struct();
    pack_params.target_energy_kWh = design.E_BESS_kWh;
    pack_params.max_power_W = design.P_BESS_kW * 1000;
    pack_params.initial_soc = SoC_initial;

    [pack_info, bess_state] = bess_pack_model( ...
        0, ...
        'init', ...
        pack_params, ...
        dt_h, ...
        []);

    state = struct();
    state.SoC = SoC_initial;
    state.bess_state = bess_state;
    state.pack_info = pack_info;
end
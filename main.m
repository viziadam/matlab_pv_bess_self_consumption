function DB =  main()
% RUN_OFFGRID_CONFIGURATION_DATABASE_CASE2
%
% Fo futtato fuggveny az off-grid PV+BESS+diesel konfiguracios
% adatbazis letrehozasahoz.
%
% Bemenet:
%   data.days(d).date
%   data.days(d).P_load_kW
%   data.days(d).P_pv_base_kW
%   data.days(d).dt_h
%
% Kimenet:
%   DB : kozponti MATLAB strukturalt adatbazis
%
% Fontos:
%   - nincs napi tabla
%   - nincs teljes idosor mentes
%   - csak candidate-szintu skalark es aggregalt napon beluli profilok mentodnek

    clc;
    close all;
    basePath = fileparts(mfilename('fullpath'));

    cfg = create_configurations(basePath);

    % [analysisResult, cfg] = analyze_load_profiles(cfg);
    % %cfg.candidates.P_inv_kW_vec = [950, 1100, 1200, 1850];
    % disp(cfg.candidates.P_inv_kW_vec);
    % 
    % data = build_data(cfg);
    % 
    % DB = init_candidate_database_structures(data, cfg);
    % 
    % DB = simulate_candidates_database(data, DB, cfg);
    % % 
    % save_candidates_database(DB, cfg);
    % 
    % fprintf('\nOff-grid candidate database simulation finished.\n');
    % fprintf('Candidates: %d\n', height(DB.candidateTable));
    % fprintf('Saved to: %s\n', fullfile(cfg.paths.results, 'offgrid_candidate_database.mat'));

    evalCfg = create_evaluation_config(cfg);
    evaluationResult = evaluation(cfg, evalCfg);

    if isfield(cfg, 'diagnostics') && isfield(cfg.diagnostics, 'enabled') && ...
       cfg.diagnostics.enabled
       DB.diagnostics = run_simulation_diagnostics(cfg, cfg.diagnostics);
    end





end
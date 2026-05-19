function results = main(runMode)
% MAIN
%
% Fo futtato fuggveny a grid-connected PV+BESS self-consumption
% esettanulmanyhoz.
%
% Alap mukodes:
%   results = main()
%
% Ez lefuttatja:
%   1) fogyasztasi/PV elozetes elemzes es inverter candidate meghatarozas,
%   2) DC-csatolt candidate sweep,
%   3) AC-csatolt candidate sweep,
%   4) AC/DC osszesito evaluation,
%   5) AC/DC osszesito utolagos javitasa: periodus NPV, helyes feliratok,
%      legkisebb invertermeretes heatmapek.
%
% Gyorsabb hasznalatok:
%   results = main("evaluateOnly")
%       Csak a mar letezo results_dccoupled.mat es results_accoupled.mat
%       alapjan keszit AC/DC osszesito kiertekelest.
%
%   results = main("dcOnly")
%       Csak DC szimulaciot futtat es kulon DC evaluation-t keszit.
%
%   results = main("acOnly")
%       Csak AC szimulaciot futtat es kulon AC evaluation-t keszit.

    if nargin < 1 || isempty(runMode)
        runMode = "full";
    end

    runMode = lower(string(runMode));

    clc;
    close all;

    basePath = fileparts(mfilename('fullpath'));
    cfg = create_configurations(basePath);

    results = struct();
    results.cfgInitial = cfg;

    switch runMode

        case "full"
            [analysisResult, cfg] = analyze_load_profiles(cfg);
            data = build_data(cfg);

            results.analysisResult = analysisResult;
            results.dcDB = local_run_coupled_simulation(data, cfg, "dc");
            results.acDB = local_run_coupled_simulation(data, cfg, "ac");
            results.acdcEvaluation = local_run_acdc_evaluation(cfg);

        case "evaluateonly"
            results.acdcEvaluation = local_run_acdc_evaluation(cfg);

        case "dconly"
            [analysisResult, cfg] = analyze_load_profiles(cfg);
            data = build_data(cfg);

            results.analysisResult = analysisResult;
            results.dcDB = local_run_coupled_simulation(data, cfg, "dc");
            results.dcEvaluation = local_run_single_evaluation(cfg, "dc");

        case "aconly"
            [analysisResult, cfg] = analyze_load_profiles(cfg);
            data = build_data(cfg);

            results.analysisResult = analysisResult;
            results.acDB = local_run_coupled_simulation(data, cfg, "ac");
            results.acEvaluation = local_run_single_evaluation(cfg, "ac");

        otherwise
            error('Unknown runMode: %s. Use "full", "evaluateOnly", "dcOnly" or "acOnly".', runMode);
    end

    results.cfgFinal = cfg;
end


% =========================================================================
% SIMULATION HELPERS
% =========================================================================
function DB = local_run_coupled_simulation(data, cfg, coupling)

    cfgRun = cfg;
    cfgRun.system.bessCoupling = coupling;

    if isfield(cfgRun, 'diagnostics') && isfield(cfgRun.diagnostics, 'testMode')
        cfgRun.diagnostics.testMode = false;
    end

    fprintf('\n============================================================\n');
    fprintf('Running %s-coupled candidate simulation.\n', upper(char(coupling)));
    fprintf('============================================================\n\n');

    DB = init_candidate_database_structures(data, cfgRun);
    DB = simulate_candidates_database(data, DB, cfgRun);
    save_candidates_database(DB, cfgRun);

    fprintf('\n%s-coupled candidate database simulation finished.\n', upper(char(coupling)));
    fprintf('Candidates: %d\n', height(DB.candidateTable));
end


function acdcEvaluation = local_run_acdc_evaluation(cfg)

    acdcEvaluation = evaluation_acdc_summary(cfg);
    acdcEvaluation = postprocess_acdc_summary_outputs(acdcEvaluation, cfg);
end


function evaluationResult = local_run_single_evaluation(cfg, coupling)

    cfgEval = cfg;
    cfgEval.system.bessCoupling = coupling;

    evalCfg = create_evaluation_config(cfgEval);

    switch string(coupling)
        case "dc"
            evalCfg.input.resultFilePath = fullfile(cfg.paths.results, 'results_dccoupled.mat');
        case "ac"
            evalCfg.input.resultFilePath = fullfile(cfg.paths.results, 'results_accoupled.mat');
        otherwise
            error('Unknown coupling: %s', string(coupling));
    end

    evalCfg.output.baseFolder = fullfile(cfg.paths.figures, 'evaluation', char(coupling));
    evaluationResult = evaluation(cfgEval, evalCfg);
end

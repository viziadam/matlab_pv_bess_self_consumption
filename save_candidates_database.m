function save_candidates_database(configurationDatabase, cfg)
% SAVE_CONFIGURATION_DATABASE
%
% Elmenti:
%   1) fo configurationDatabase .mat fajl
%   2) summary tabla .csv fajl

    if ~exist(cfg.paths.results, 'dir')
        mkdir(cfg.paths.results);
    end
    
    if cfg.system.bessCoupling == "dc"
        matPath = fullfile(cfg.paths.results, 'results_dccoupled.mat');
        csvPath = fullfile(cfg.paths.results, 'results_dccoupled.csv');
    else
        matPath = fullfile(cfg.paths.results, 'results_accoupled.mat');
        csvPath = fullfile(cfg.paths.results, 'results_accoupled.csv');
    end

    save(matPath, 'configurationDatabase', '-v7.3');

    if isfield(configurationDatabase, 'summaryTable') && ~isempty(configurationDatabase.summaryTable)
        writetable(configurationDatabase.summaryTable, csvPath);
    end

    fprintf('\nMain database saved:\n%s\n', matPath);
    fprintf('Summary table saved:\n%s\n', csvPath);
end
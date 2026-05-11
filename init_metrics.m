function running = init_metrics(nT, cfg)
% INIT_METRICS
%
% Candidate-szintu futas kozbeni metrikatarolo inicializalasa.
%
% A metrikak listaja a cfg.output.scalarMetrics es
% cfg.output.profileMetrics strukturabol jon.

    running = struct();

    running.nDays = 0;

    running.scalar = struct();
    running.profileSum = struct();
    running.profileMax = struct();
    running.profileMin = struct();

    % ---------------------------------------------------------------------
    % Scalar metrics
    % ---------------------------------------------------------------------
    for i = 1:numel(cfg.output.scalarMetrics)

        m = cfg.output.scalarMetrics(i);

        switch string(m.mode)

            case "max"
                running.scalar.(m.name) = -inf;

            otherwise
                running.scalar.(m.name) = 0;
        end
    end

    % ---------------------------------------------------------------------
    % Profile metrics
    % ---------------------------------------------------------------------
    for i = 1:numel(cfg.output.profileMetrics)

        m = cfg.output.profileMetrics(i);

        switch string(m.mode)

            case "meanProfile"
                running.profileSum.(m.name) = zeros(1, nT);

            case "maxProfile"
                running.profileMax.(m.name) = -inf(1, nT);

            case "minProfile"
                running.profileMin.(m.name) = inf(1, nT);

            otherwise
                error('Ismeretlen profile metric mode: %s', string(m.mode));
        end
    end
end
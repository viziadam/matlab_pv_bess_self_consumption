function running = update_metrics(running, dayVectors, dt_h, cfg)
% UPDATE_METRICS
%
% Egy nap dayVectors eredmenyeivel frissiti a candidate-szintu
% running metrikakat.
%
% Bemenet:
%   running    - init_metrics altal letrehozott struktura
%   dayVectors - napi szimulacio eredmenyei
%   dt_h       - mintaveteli ido oraban
%   cfg        - konfiguracio
%
% Tamogatott scalar mode-ok:
%   energySum : sum(P_kW) * dt_h
%   sum       : sum(vector)
%   max       : max(vector)
%
% Tamogatott profile mode-ok:
%   meanProfile : napok kozotti atlagprofilhoz osszegzes
%   maxProfile  : napon beluli idopontonkénti maximum
%   minProfile  : napon beluli idopontonkénti minimum

    strictSources = true;

    if isfield(cfg, 'sim') && isfield(cfg.sim, 'strictMetricSources')
        strictSources = cfg.sim.strictMetricSources;
    end

    % ---------------------------------------------------------------------
    % Scalar metrics
    % ---------------------------------------------------------------------
    for i = 1:numel(cfg.output.scalarMetrics)

        m = cfg.output.scalarMetrics(i);

        sourceName = char(m.source);
        metricName = char(m.name);
        modeName = string(m.mode);

        x = local_get_day_vector(dayVectors, sourceName, strictSources);

        switch modeName

            case "energySum"
                value = sum(x, 'omitnan') * dt_h;

            case "sum"
                value = sum(x, 'omitnan');

            case "max"
                value = max(x, [], 'omitnan');

            otherwise
                error('Ismeretlen scalar metric mode: %s', modeName);
        end

        switch modeName

            case "max"
                running.scalar.(metricName) = max(running.scalar.(metricName), value);

            otherwise
                running.scalar.(metricName) = running.scalar.(metricName) + value;
        end
    end

    % ---------------------------------------------------------------------
    % Profile metrics
    % ---------------------------------------------------------------------
    for i = 1:numel(cfg.output.profileMetrics)

        m = cfg.output.profileMetrics(i);

        sourceName = char(m.source);
        metricName = char(m.name);
        modeName = string(m.mode);

        x = local_get_day_vector(dayVectors, sourceName, strictSources);
        x = x(:).';

        switch modeName

            case "meanProfile"
                running.profileSum.(metricName) = running.profileSum.(metricName) + x;

            case "maxProfile"
                running.profileMax.(metricName) = max(running.profileMax.(metricName), x);

            case "minProfile"
                running.profileMin.(metricName) = min(running.profileMin.(metricName), x);

            otherwise
                error('Ismeretlen profile metric mode: %s', modeName);
        end
    end

    running.nDays = running.nDays + 1;
end


function x = local_get_day_vector(dayVectors, sourceName, strictSources)

    if isfield(dayVectors, sourceName)
        x = dayVectors.(sourceName);
        return;
    end

    if strictSources
        error('A dayVectors nem tartalmazza a kovetkezo mezot: %s', sourceName);
    else
        warning('Hianyzo dayVectors mezo: %s. Nullaval helyettesitem.', sourceName);
        x = 0;
    end
end
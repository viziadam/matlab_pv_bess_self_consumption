function data = build_data(cfg)
% BUILD_DATA
%
% PV es fogyasztasi adatok szinkronizalt betoltese off-grid szimulaciohoz.
%
% Kimenet:
%   data.days(d).date
%   data.days(d).P_load_kW
%   data.days(d).P_pv_base_kW
%   data.days(d).dt_h
%
% Fontos:
%   P_pv_base_kW 1 kWp referencia PV termeles [kW].
%
%   A szimulacioban kesobb:
%       P_pv_available_kW = P_pv_base_kW * design.PV_kW
%
% Szinkronizalas:
%   Csak azok a napok kerulnek be, amelyeknel ugyanaz a datum
%   megtalalhato a fogyasztasi es a PV adatok kozott is.

    if ~isfield(cfg, 'pv')
        error('cfg.pv is missing.');
    end

    requiredPvFields = {'tiltX', 'tiltZ', 'referencePdc_kWp', 'modulePower_kWp'};

    for k = 1:numel(requiredPvFields)
        if ~isfield(cfg.pv, requiredPvFields{k})
            error('Missing cfg.pv.%s', requiredPvFields{k});
        end
    end

    % ---------------------------------------------------------------------
    % Optional load scaling for testing
    % ---------------------------------------------------------------------
    loadScale = 1.0;

    if isfield(cfg, 'loadScale')
        loadScale = cfg.loadScale;
    end

    if ~isnumeric(loadScale) || ~isscalar(loadScale) || ~isfinite(loadScale) || loadScale <= 0
        error('cfg.loadScale must be a positive finite scalar.');
    end

    fprintf('Load scale factor: %.4f\n', loadScale);

    Load = build_load_cache();

    PV = build_pv_cache( ...
        cfg.pv.tiltX, ...
        cfg.pv.tiltZ, ...
        cfg.pv.referencePdc_kWp, ...
        cfg.pv.modulePower_kWp);

    if isempty(Load) || isempty(PV)
        error('Load or PV cache is empty.');
    end

    loadDates = [Load.date].';
    pvDates = [PV.date].';

    [commonDates, idxLoad, idxPV] = intersect(loadDates, pvDates);

    if isempty(commonDates)
        error('No common dates found between Load and PV data.');
    end

    nDays = numel(commonDates);

    fprintf('\nSynchronization by exact dates:\n');
    fprintf('  Load days:   %d\n', numel(Load));
    fprintf('  PV days:     %d\n', numel(PV));
    fprintf('  Common days: %d\n', nDays);
    fprintf('  First common date: %s\n', datestr(commonDates(1), 'yyyy-mm-dd'));
    fprintf('  Last common date:  %s\n', datestr(commonDates(end), 'yyyy-mm-dd'));

    data = struct();
    data.days = repmat( ...
        struct('date', NaT, 'P_load_kW', [], 'P_pv_base_kW', [], 'dt_h', []), ...
        1, nDays);

    for d = 1:nDays

        L = Load(idxLoad(d));
        P = PV(idxPV(d));

        P_load_kW_raw = L.P_load_kW(:).';
        P_load_kW = loadScale .* P_load_kW_raw;
        dt_load_h = L.dt_h;

        P_pv_base_kW = P.Ppv(:).';
        dt_pv_h = P.dt_h;

        if abs(dt_pv_h - dt_load_h) > 1e-12
            P_pv_base_kW = local_resample_power_to_target_dt(P_pv_base_kW, dt_pv_h, dt_load_h);
            dt_pv_h = dt_load_h;
        end

        if numel(P_pv_base_kW) ~= numel(P_load_kW)
            error(['Length mismatch after synchronization at date %s. ', ...
                   'Load length = %d, PV length = %d.'], ...
                   datestr(commonDates(d), 'yyyy-mm-dd'), ...
                   numel(P_load_kW), numel(P_pv_base_kW));
        end

        if abs(dt_pv_h - dt_load_h) > 1e-12
            error('dt_h mismatch after synchronization at date %s.', ...
                datestr(commonDates(d), 'yyyy-mm-dd'));
        end

        data.days(d).date = commonDates(d);
        data.days(d).P_load_kW = P_load_kW;
        data.days(d).P_pv_base_kW = P_pv_base_kW;
        data.days(d).dt_h = dt_load_h;
    end

    data.info = struct();
    data.info.createdAt = datetime('now');
    data.info.nDays = nDays;
    data.info.dt_h = data.days(1).dt_h;
    data.info.nT = numel(data.days(1).P_load_kW);

    data.info.loadScale = loadScale;
    data.info.noteLoadScale = "Load time series was scaled by cfg.loadScale during build_data.";

    data.info.firstDate = commonDates(1);
    data.info.lastDate = commonDates(end);

    data.info.rawLoadDays = numel(Load);
    data.info.rawPvDays = numel(PV);
    data.info.commonDays = nDays;

    data.info.pvReferencePdc_kWp = sum(cfg.pv.referencePdc_kWp);
    data.info.pvTiltX = cfg.pv.tiltX;
    data.info.pvTiltZ = cfg.pv.tiltZ;
    data.info.note = "PV is stored as 1 kWp reference production. Scale with design.PV_kW.";

    fprintf('\nOff-grid time series synchronized.\n');
    fprintf('Days: %d\n', data.info.nDays);
    fprintf('Steps per day: %d\n', data.info.nT);
    fprintf('dt_h: %.6f h\n', data.info.dt_h);
    fprintf('PV reference size: %.3f kWp\n', data.info.pvReferencePdc_kWp);
end


function y = local_resample_power_to_target_dt(x, dt_in_h, dt_out_h)
% LOCAL_RESAMPLE_POWER_TO_TARGET_DT
%
% Teljesitmeny idosor atalakitas masik idofelbontasra.
%
% Ha dt_out_h > dt_in_h:
%   nagyobb idolepesre atlagol.
%
% Ha dt_out_h < dt_in_h:
%   kisebb idolepesre ismetlessel bontja fel.
%
% Teljesitmenyadatnal ez egyszeru es stabil megoldas.
% Az energia egyensuly megmarad, ha kesobb teljesitmeny * dt_h alapon szamolsz.

    x = x(:).';

    if abs(dt_in_h - dt_out_h) < 1e-12
        y = x;
        return;
    end

    if dt_out_h > dt_in_h

        factorReal = dt_out_h / dt_in_h;
        factor = round(factorReal);

        if abs(factorReal - factor) > 1e-9
            error('Target dt_h must be an integer multiple of input dt_h.');
        end

        nBlocks = floor(numel(x) / factor);

        if nBlocks < 1
            error('Not enough samples for resampling.');
        end

        nUse = nBlocks * factor;

        xUse = x(1:nUse);
        xMat = reshape(xUse, factor, nBlocks);

        y = mean(xMat, 1);

    else

        factorReal = dt_in_h / dt_out_h;
        factor = round(factorReal);

        if abs(factorReal - factor) > 1e-9
            error('Input dt_h must be an integer multiple of target dt_h.');
        end

        y = repelem(x, factor);
    end
end
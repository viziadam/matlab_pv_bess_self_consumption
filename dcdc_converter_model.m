function out = dcdc_converter_model(P_input_W, P_max_W, dt_h, mode)
% DCDC_CONVERTER_MODEL
%
% Ketiranyu DC/DC konverter modell a DC sin es a BESS pack kozott.
%
% Uzemmodok:
%
%   mode = 'dc_to_pack'
%       A bemenet a DC sin oldali teljesitmenykeres.
%       Kimenet a pack oldali teljesitmenykeres.
%
%       Jelkonvencio:
%           P_input_W > 0  -> kisutes, DC sinre szeretnenk teljesitmenyt kapni
%           P_input_W < 0  -> toltes, DC sinrol szeretnenk akkut tolteni
%
%   mode = 'pack_to_dc'
%       A bemenet a BESS pack tenyleges teljesitmenye.
%       Kimenet a DC sin oldali tenyleges teljesitmeny.
%
%       Jelkonvencio:
%           P_input_W > 0  -> pack kisut, teljesitmeny megy a DC sin fele
%           P_input_W < 0  -> pack toltodik, teljesitmeny jon a DC sin felol
%
% Bemenet:
%   P_input_W : teljesitmenyvektor [W]
%   P_max_W   : DC/DC nevleges teljesitmenykorlat [W]
%   dt_h      : idolepes [h]
%   mode      : 'dc_to_pack' vagy 'pack_to_dc'
%
% Kimenet:
%   out.P_input_W
%   out.P_input_clipped_W
%   out.P_output_W
%   out.P_loss_W
%   out.P_clipped_W
%
%   out.E_input_kWh
%   out.E_output_kWh
%   out.E_loss_kWh
%   out.E_clipped_kWh
%
% Megjegyzes:
%   A hatasfokok a modellben vannak definialva, nem cfg-ben.

    P_input_W = P_input_W(:).';
    P_max_W = abs(P_max_W);

    eta_ch = 0.975;
    eta_dis = 0.975;

    if P_max_W <= 0
        out = local_zero_output(P_input_W, dt_h);
        out.P_clipped_W = abs(P_input_W);
        out.E_clipped_kWh = abs(P_input_W) * dt_h / 1000;
        return;
    end

    switch lower(mode)

        case 'dc_to_pack'
            % Bemenet: DC sin oldali keres
            % Kimenet: pack oldali keres

            P_input_clipped_W = max(-P_max_W, min(P_input_W, P_max_W));

            P_output_W = zeros(size(P_input_W));

            mask_chg = P_input_clipped_W < 0;
            mask_dis = P_input_clipped_W > 0;

            % Toltes:
            % DC sinrol jon teljesitmeny, az akkuba kevesebb jut.
            P_output_W(mask_chg) = P_input_clipped_W(mask_chg) * eta_ch;

            % Kisutes:
            % DC sinre adott teljesitmenyhez a packtol tobb kell.
            P_output_W(mask_dis) = P_input_clipped_W(mask_dis) / eta_dis;

            P_loss_W = abs(P_output_W - P_input_clipped_W);
            P_clipped_W = abs(P_input_W - P_input_clipped_W);

        case 'pack_to_dc'
            % Bemenet: pack tenyleges teljesitmenye
            % Kimenet: DC sin oldali tenyleges teljesitmeny

            P_input_clipped_W = max(-P_max_W, min(P_input_W, P_max_W));

            P_output_W = zeros(size(P_input_W));

            mask_chg = P_input_clipped_W < 0;
            mask_dis = P_input_clipped_W > 0;

            % Toltes:
            % Ha a packba ennyi ment be, akkor a DC sinrol tobb kellett.
            P_output_W(mask_chg) = P_input_clipped_W(mask_chg) / eta_ch;

            % Kisutes:
            % Ha a pack ennyit adott ki, akkor a DC sinre kevesebb jut.
            P_output_W(mask_dis) = P_input_clipped_W(mask_dis) * eta_dis;

            P_loss_W = abs(P_output_W - P_input_clipped_W);
            P_clipped_W = abs(P_input_W - P_input_clipped_W);

        otherwise
            error('Unknown DC/DC mode: %s. Use dc_to_pack or pack_to_dc.', mode);
    end

    out = struct();

    out.P_input_W = P_input_W;
    out.P_input_clipped_W = P_input_clipped_W;
    out.P_output_W = P_output_W;
    out.P_loss_W = P_loss_W;
    out.P_clipped_W = P_clipped_W;

    out.E_input_kWh = abs(P_input_clipped_W) * dt_h / 1000;
    out.E_output_kWh = abs(P_output_W) * dt_h / 1000;
    out.E_loss_kWh = P_loss_W * dt_h / 1000;
    out.E_clipped_kWh = P_clipped_W * dt_h / 1000;
end


function out = local_zero_output(P_input_W, dt_h)

    z = zeros(size(P_input_W));

    out = struct();

    out.P_input_W = P_input_W;
    out.P_input_clipped_W = z;
    out.P_output_W = z;
    out.P_loss_W = z;
    out.P_clipped_W = z;

    out.E_input_kWh = z;
    out.E_output_kWh = z;
    out.E_loss_kWh = z;
    out.E_clipped_kWh = z;
end
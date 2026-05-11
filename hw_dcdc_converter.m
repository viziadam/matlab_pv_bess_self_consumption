function [P_low_W, P_loss_W] = hw_dcdc_converter(P_high_W, P_max_W, eta_c, eta_d)
    % HW_DCDC_CONVERTER - Kétirányú DC/DC konverter hardver modul
    % P_high_W: Teljesítmény a magas feszültségű oldalon (DC Sín) [W]
    % P_max_W : A konverter hardveres teljesítménykorlátja (0.5C alapján) [W]
    % 
    % Irány konvenció: 
    % Negatív (-) = Töltés, Pozitív (+) = Kisütés
    
    N = length(P_high_W);
    P_low_W = zeros(1, N);
    
    % --- FIZIKAI HARDVER KORLÁT (Clipping a DC/DC konverteren) ---
    % Nem engedhet át nagyobb áramot, mint a névleges maximuma!
    P_high_clipped_W = max(-P_max_W, min(P_high_W, P_max_W));
    
    mask_chg = P_high_clipped_W < 0;
    mask_dis = P_high_clipped_W > 0;
    
    % Töltéskor a veszteség miatt kevesebb energia jut az akkuba
    P_low_W(mask_chg) = P_high_clipped_W(mask_chg) * eta_c;
    
    % Kisütéskor a veszteség miatt több energiát kell kérni az akkutól
    P_low_W(mask_dis) = P_high_clipped_W(mask_dis) / eta_d;
    
    % Konverter hőveszteség (A ténylegesen átment energia alapján)
    P_loss_W = abs(P_high_clipped_W - P_low_W);
end
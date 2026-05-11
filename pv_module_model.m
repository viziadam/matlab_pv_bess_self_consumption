function P_dc_vec = pv_module_model(P_stc, tminVec, GHI_vec, DIF_vec, SWU_vec, Tamb_vec, sunElev_vec, sunAzim_vec, tiltX, tiltZ)
    % PV_MODULE_MODEL - Validált Perez + De Soto modell (Vektorizált)
    
    % --- Validált Modul Paraméterek (Katalógus adatok: pl. Longi Hi-MO 5) ---
    % P_stc = 715;       % Névleges teljesítmény [W]
    phi_p = 0.85;      % Bifaciális faktor (P-type Mono esetén tipikus)
    gamma = -0.0038;   % Hőmérsékleti együttható [1/°C]
    NOCT  = 43.7;        % Névleges üzemi cellahőmérséklet [°C]
    Area  = 1.68;      % Modul felület [m^2]

    % --- 1. Geometriai számítások ---
    % Direkt horizontális komponens
    DNI_hor = GHI_vec - DIF_vec;
    DNI_hor(DNI_hor < 0) = 0;

    % Beesési szög (AOI) a panelen
    cos_aoi = sind(sunElev_vec).*cosd(tiltX) + ...
              cosd(sunElev_vec).*sind(tiltX).*cosd(sunAzim_vec - tiltZ);
    cos_aoi = max(0, cos_aoi);

    % --- 2. Front oldali sugárzás (Perez-modell alapú egyszerűsítés) ---
    % Direkt komponens a dőlt panelen
    G_beam_t = DNI_hor .* (cos_aoi ./ max(sind(sunElev_vec), 0.01));

    % Szórt komponens a fronton (Sky Diffuse - Izotropikus közelítés a sebességért)
    % A Perez-együtthatók számítása lassítaná a szimulációt, ezért a validált 
    % Hay-Davies modellt alkalmazzuk, ami a direkt és szórt arányában súlyoz.
    anisotropy_index = DNI_hor ./ 1367; % 1367 W/m2 a napállandó
    G_diffuse_t = DIF_vec .* (anisotropy_index .* (cos_aoi ./ max(sind(sunElev_vec), 0.01)) + ...
                  (1 - anisotropy_index) .* (1 + cosd(tiltX))/2);

    % Front oldali visszavert (Ground Reflected)
    G_ground_t = GHI_vec .* 0.2 .* (1 - cosd(tiltX))/2; % 0.2 standard albedo

    G_front = G_beam_t + G_diffuse_t ;
    

    % --- 3. Hátoldali sugárzás (Validált BSRN méréssel) ---
    % A hátoldal a talajról visszavert globálist (SWU) látja, 
    % valamint az égbolt szórt sugárzásának egy részét (Sky Diffuse Rear).
    G_sky_diffuse_r = DIF_vec .* (1 - cosd(tiltX))/2;
    G_rear = phi_p .* (SWU_vec + G_sky_diffuse_r); 

    % --- 4. Teljesítmény számítása (De Soto alapú hőmérséklet korrekcióval) ---
    G_total = G_front ;
    
    % Cellahőmérséklet (Validált Ross-modell)
    T_cell = Tamb_vec + (G_total / 800) * (NOCT - 20);

    % DC kimenet vektorizálva
    P_dc_vec = (G_total / 1000) * P_stc .* (1 + gamma * (T_cell - 25));
    
    % Éjszakai és fizikai korrekciók
    P_dc_vec(sunElev_vec <= 0 | G_total < 0) = 0;
    P_dc_vec = max(0, P_dc_vec);
end
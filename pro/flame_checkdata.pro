
PRO flame_checkdata_refstar, fuel
;
; Use the final stacked spectrum of the reference star to measure and plot
; the effective seeing, and track seeing and vertical position as a function of wavelength.
; Also extract and plot the 1D spectrum.
;

	; check if the reference star has been specified
	if fuel.input.star_y_A eq 0.0 then return

	; set the output directory without skysub
	output_dir = fuel.util.output_dir + 'spec2d' + path_sep()

	; x coordinate where the star trace is certainly visible
	star_x = mean(fuel.settings.star_x_range)

	; identify the slit with the reference star
	i_ref = -1
	for i_slit=0, n_elements(fuel.slits)-1 do $
		if fuel.input.star_y_A GE poly(star_x, fuel.slits[i_slit].bottom_poly) $
			and fuel.input.star_y_A LE poly(star_x, fuel.slits[i_slit].bottom_poly) + $
			fuel.slits[i_slit].height then $
				i_ref = i_slit

	; if there is no slit with the reference star, then exit
	if fuel.slits[i_ref].skip then begin
		print, 'Did not find the slit with the reference star.'
		return
	endif

	print, 'Reference star is in slit number ', strtrim(fuel.slits[i_ref].number, 2)
  cgPS_open, fuel.util.output_dir + 'reference_star.ps', /nomatch


	; load output spectrum of reference star
	; --------------------------------------

	; load output file
	ref_spec = mrdfits(output_dir + fuel.slits[i_ref].output_combined_file, 0, header, /silent)

	; get the wavelength calibration from the header
 	lambda_unit = strlowcase( strtrim(sxpar(header, 'CUNIT1'), 2) )
	lambda_axis = sxpar(header, 'CRVAL1') + sxpar(header,'CDELT1') * $
		( findgen(sxpar(header,'NAXIS1')) )


 	; median profile and fit
 	; -----------------------------

	; get an idea of the seeing from the diagnostics
	approx_seeing = median([fuel.diagnostics.seeing])		; FWHM, in arcsec
	approx_seeing /= fuel.instrument.pixel_scale		; FWHM, in pixels

	; make the y-axis in units of gamma
	yaxis_cutout = dindgen( (size(ref_spec))[2] ) + sxpar(header, 'CRVAL2')

	; select only the region around the reference star (which is by definition at gamma=0)
	w_region = where(abs(yaxis_cutout) LT 7.0*approx_seeing, /NULL)
	if n_elements(w_region) LT 4 then message, 'Could not detect the trace of the reference star'

	; extract the spatial profile
	ref_profile_cutout = median(ref_spec, dimension=1)

	; trim the profile to the region of interest
	ref_profile = ref_profile_cutout[w_region]
	yaxis = yaxis_cutout[w_region]

	; fit a gaussian to the integrated profile
	est_peak = max(ref_profile)
  fit_result = gaussfit(yaxis, ref_profile, ref_coeff, nterms=4, $
    estimates=[ est_peak, 0.0, approx_seeing/2.36, 0.0], $
    chisq=chisq, sigma=coeff_err)

	; calculate seeing in arcsec
	median_seeing = 2.355 * ref_coeff[2] * fuel.instrument.pixel_scale
	print, 'The final effective seeing calculated from the reference star is ' + $
	 	cgnumber_formatter(median_seeing, decimals=2) + ' arcsec.'
	print, ''

	; plot the median profile
	cgplot, yaxis, ref_profile, psym=16, charsize=1, xtit='y pixel coordinate', $
		ytit='median flux', title='reference star: median profile (seeing = ' + $
		cgnumber_formatter(median_seeing, decimals=2) + ' arcsec)'

	; overplot Gaussian fit
	xaxis = yaxis[0] + dindgen(300)/299.0*(yaxis[-1]-yaxis[0])
	cgplot, xaxis, ref_coeff[0] * exp( -0.5* ( (xaxis-ref_coeff[1])/ref_coeff[2] )^2 ) + ref_coeff[3], $
		/overplot, color='red', thick=3


	; fit profile as a function of wavelength
	; ----------------------------------------

	; set the bin size, in pixels, along the wavelength direction
	binsize = 100
	starting_pixel = 0

	; dimensions
	N_pixel_x = (size(ref_spec))[1]
	N_pixel_y = (size(ref_spec))[2]

	; empty arrays for seeing and position measurement
	coord_x = []
	seeing = []
	center = []

	while starting_pixel LT N_pixel_x do begin

    ; extract the bin
    end_pixel = min([starting_pixel + binsize - 1, N_pixel_x-1])
    cutout_bin = ref_spec[starting_pixel : end_pixel, *]

    ; spatial profile
    profile = median(cutout_bin, dimension=1)

		; range to fit
		wfit = where( abs(yaxis_cutout) LT 3.0*approx_seeing and finite(profile), /null )

		; if there's nothing to fit, skip this bin
		if n_elements(wfit) GT 4 then begin

			; fit a Gaussian
			fit_result = gaussfit(yaxis_cutout[wfit], profile[wfit], coeff, nterms=4, $
	    	estimates=ref_coeff, $
	    	chisq=chisq, sigma=coeff_err)

			; save the result of the fit
			coord_x = [coord_x, 0.5*(starting_pixel+end_pixel)]
			seeing = [seeing, 2.355 * coeff[2] * fuel.instrument.pixel_scale]
			center = [center, coeff[1]]

		endif

    ; advance to next bin
    starting_pixel += binsize

  endwhile

	; plot seeing as a function of wavelength
	cgplot, coord_x, seeing, thick=4, charsize=1, $
		ytit='seeing (arcsec)', $
		yra=[min(seeing, /nan)-0.1, max(seeing, /nan)+0.1], $
		xra=[0, N_pixel_x], xsty=1+8, xthick=4, ythick=4, $
		position = [0.15, 0.55, 0.9, 0.9], xtickformat='(A1)'

	; top x-axis with pixel coordinate
	cgaxis, xaxis=1, xra = [ 0 , N_pixel_x ], xsty=1, charsize=1, $
		xtit='x-coordinate (pixel)'

	; show the median seeing
	cgplot, [0, N_pixel_x], [0,0]+median_seeing, /overplot, thick=3, linestyle=2

	; make center relative to initial position
	center -= center[0]

	; show centering as a function of wavelength
	cgplot, coord_x, center, thick=4, charsize=1, $
		xtit='x-coordinate (pixel)', ytit='center position (pixel)', $
		yra=[min(center, /nan)-1.0, max(center, /nan)+1.0], $
		xra=[0, N_pixel_x], xsty=1+4, xthick=4, ythick=4, $
		position = [0.15, 0.15, 0.9, 0.55], /noerase

	; bottom x-axis with wavelength
	cgaxis, xaxis=0, xra = [ lambda_axis[0] , lambda_axis[-1] ], xsty=1, charsize=1, $
		xtit='wavelength (' + lambda_unit + ')'

	; overplot zero line
	cgplot, [0, N_pixel_x], [0,0], /overplot, thick=3, linestyle=2


	; extract and plot 1D spectrum of reference star
	; ----------------------------------------------

	; extract spectrum from +/- 2 sigma around the center
	w_extract = where( abs(yaxis_cutout-ref_coeff[1]) LT 2.0*ref_coeff[2], /NULL)

	; extract boxcar spectrum
	spectrum = total(ref_spec[ * , min(w_extract):max(w_extract) ], 2, /nan)

	; show star spectrum
	cgplot, lambda_axis, smooth(spectrum, 17), charsize=1, $
		xtit='wavelength (' + lambda_unit + ')', ytit='flux', /ynozero, $
		title='boxcar extraction of the reference star spectrum'


	cgPS_close

END



;*******************************************************************************
;*******************************************************************************
;*******************************************************************************


PRO flame_checkdata_skycontinuum, fuel, lambda1d, spec1d

	; load sky model
  readcol, fuel.settings.sky_emission_filename, model_lambda, model_flux	; lambda in micron

	; trim to the wavelength of interest
	w_touse = where(model_lambda GT lambda1d[0] and model_lambda LT lambda1d[-1], /null)
	model_lambda = model_lambda[w_touse]
	model_flux = model_flux[w_touse]

	; slightly smooth model
	model_flux = median(model_flux, 5)

	; resample model onto the observed wavelength grid
	model_flux_resampled = interpol( model_flux, model_lambda, lambda1d)

  ; clean observed spectrum from NaNs because they don't work with the cross correlation
  spec1d_clean = spec1d
  spec1d_clean[ where(~finite(spec1d), /null) ] = 0.0

	; determine the region in common between model and observed spectrum
	w_incommon = where( median( spec1d_clean * model_flux_resampled, 15) GT 0.0, /null)
	min_x = min(w_incommon, /nan)
	max_x = max(w_incommon, /nan)

	; split the part in common into bins of approximately 500 (observed) pixels
	N_bins = round( float(max_x - min_x) / 500.0 )
	bin_size = round( float(max_x-min_x) / float(N_bins) )

	; arrays that will contain the result
	shift_x = []
	shift_y = []

	; for each bin, perform cross-correlation
	for i_bin=0,N_bins-1 do begin

		; extract the spectra in this bin
		bin_range = [min_x + i_bin*bin_size , min_x + (i_bin+1)*bin_size < max_x-1]
		bin_model = model_flux_resampled[bin_range[0] : bin_range[1]]
		bin_obs = spec1d_clean[bin_range[0] : bin_range[1]]
		bin_lambda = lambda1d[bin_range[0] : bin_range[1]]

		; upsample by a factor of 10
		bin_model_up = rebin(bin_model, 10*n_elements(bin_model))
		bin_obs_up = rebin(bin_obs, 10*n_elements(bin_obs))
		bin_lambda_up = rebin(bin_lambda, 10*n_elements(bin_obs))

		; smooth and normalize
		bin_model_up = median(bin_model_up, 50) / median(bin_model_up)
		bin_obs_up = median(bin_obs_up, 50) / median(bin_obs_up)

		; measure the local shift between observed and model spectrum
	  lag = indgen(100)-50 ; up to 5 pixels each direction
	  crosscorr = c_correlate( bin_obs_up, bin_model_up, lag)
	  max_crosscorr = max( crosscorr, max_ind, /nan)
	  delta = -lag[max_ind] * (lambda1d[1]-lambda1d[0])/10.0

		; show the shifted spectra
		cgplot, bin_lambda_up, bin_model_up, color='red', thick=3, xtit='wavelength (micron)', $
			title='cross-correlation of observed vs model sky', charsize=1, /ynozero
		cgplot, bin_lambda_up, shift(bin_obs_up, lag[max_ind]), thick=2, /overplot

		; save the result
		shift_x = [shift_x, mean(bin_lambda_up)]
		shift_y = [shift_y, delta]

	endfor

	; plot summary of typical shifts
	lambda_shift = median(shift_y)
	cgplot, shift_x, shift_y*1d4, psym=-16, charsize=1, xtit='wavelength (micron)', ytit='wavelength shift (angstrom)'
	cgplot, [-1, 2*shift_x[-1]], [0,0], /overplot, linestyle=2


END


;*******************************************************************************
;*******************************************************************************
;*******************************************************************************



PRO flame_checkdata_sky, fuel, i_slit=i_slit
;
; For each slit, use the final stacked sky spectrum to measure spectral resolution
; and residuals of the wavelength calibration. Show plot and print stats.
;

	print, 'Checking slit number ' + strtrim(fuel.slits[i_slit].number, 2)


	; load the sky spectrum for this slit
	;-------------------------------------

	; filename of the output sky stack
	skystack_filename = fuel.util.output_dir + 'spec2d' + path_sep() + $
	 	fuel.slits[i_slit].output_file

	; load the sky spectrum
	sky_spec2d = mrdfits(skystack_filename, 3, header, /silent)
	header = headfits(skystack_filename)

	; extract 1D spectrum
	sky_spec =  median(sky_spec2d, dimension=2)

	; get the wavelength calibration from the header
 	lambda_unit = strlowcase( strtrim(sxpar(header, 'CUNIT1'), 2) )
	lambda_axis = sxpar(header, 'CRVAL1') + sxpar(header,'CDELT1') * $
		( findgen(sxpar(header,'NAXIS1')) )

	; for now we only support micron
	if lambda_unit ne 'micron' then message, lambda_unit + ' not supported!'


	; fit the OH lines
	;-------------------------------------

	; load line list
	readcol, fuel.settings.linelist_sky_filename, line_list, line_trust, format='D,I', /silent

	; keep only the ones that can be used for the wavelength solution
	line_list = line_list[where(line_trust eq 1, /null)]

  ; calculate approximate sky line width
	linewidth_um = median(lambda_axis) / (2.36 * fuel.instrument.resolution_slit1arcsec)

	; identify the OH lines that are in this wavelength range
	w_lines = where(line_list GT min(lambda_axis, /nan)+6.0*linewidth_um $
		AND line_list LT max(lambda_axis, /nan)-6.0*linewidth_um, /null )

	; if there are very few lines, then use the sky continuum
	if n_elements(w_lines) LT 5 then flame_checkdata_skycontinuum, fuel, lambda_axis, sky_spec

	; make sure there are sky lines here
	if w_lines EQ !NULL then begin
    print, 'Warning: wavelength range does not contain sky lines'
		return
  endif

	; keep only the OH lines of interest
	line_list = line_list[w_lines]

	; arrays for the fit results
	sky_lambda_th = []
	sky_lambda_obs = []
	sky_sigma = []

	; fit a Gaussian to every sky line
	for i_line=0,n_elements(line_list)-1 do begin

		; select the region to fit
		w_fit = where( abs(lambda_axis-line_list[i_line]) LT 6.0*linewidth_um, /null )

		; check that the region is within the observed range
		if w_fit eq !NULL then continue

    ; check that there actually is signal and it's not just a bunch of NaNs
    if n_elements( where( finite(sky_spec[w_fit]), /null ) ) LE 5 then continue

		; error handling for the gaussian fitting
		catch, error_gaussfit
		if error_gaussfit ne 0 then begin
			print, 'GAUSSFIT ERROR STATUS: ' + strtrim(error_gaussfit,2)
			catch, /cancel
			continue
		endif

		; estimate parameters of the Gaussian
		est_peak = max( median( sky_spec[w_fit], 3) , /nan)
		est_center = line_list[i_line]
		est_sigma = linewidth_um
		est_cont = min( median( sky_spec[w_fit], 3) , /nan)

		; Gaussian fit
		!NULL = gaussfit( lambda_axis[w_fit], sky_spec[w_fit], gauss_param, nterms=4, $
			estimates=[est_peak, est_center, est_sigma, est_cont], sigma=gauss_err, chisq=chisq )

		; check that chi square makes sense
		if ~finite(chisq) then continue

		; check that the peak of the Gaussian is positive
		if gauss_param[0] LT 0.0 then continue

		; check that the SNR is high
		if gauss_param[0] LT 5.0*gauss_err[0] then continue

		; check that the center of the Guassian is in the observed range
		if gauss_param[1] LT min(lambda_axis[w_fit]) or gauss_param[1] GT max(lambda_axis[w_fit]) then continue

		; check that the Gaussian width makes sense
		if gauss_param[2] LT linewidth_um/10.0 or gauss_param[2] GT linewidth_um*10.0 then continue

		; save the results
		sky_lambda_th = [sky_lambda_th, line_list[i_line] ]
		sky_lambda_obs = [sky_lambda_obs, gauss_param[1] ]
		sky_sigma = [sky_sigma, gauss_param[2] ]

	endfor

	; calculate the wavelength residuals in angstrom
	residuals = 1d4 * (sky_lambda_th-sky_lambda_obs)

	; calculate the spectral resolution R
	spectral_R = sky_lambda_th/(sky_sigma*2.36)

	; plot the result of the fit
	;-------------------------------------

	; x axis range
	xra=[lambda_axis[0], lambda_axis[-1]]


	; panel 1: plot the spectrum
	cgplot, lambda_axis, sky_spec, charsize=0.8, xsty=1, xtit='', ytit='sky flux', $
		title = skystack_filename, position = [0.10, 0.70, 0.95, 0.95], $
		xtickformat="(A1)", xra=xra, /nodata

	; show the OH lines that were identified
	for i_line=0, n_elements(sky_lambda_th)-1 do $
		cgplot, sky_lambda_th[i_line] + [0,0], [-2,2]*max(abs(sky_spec)), /overplot, color='red'

	; show the spectrum on top, for clarity
	cgplot, lambda_axis, sky_spec, /overplot


	; panel 2: show the residuals
	cgplot, sky_lambda_th, residuals, /ynozero, xra=xra, $
		xsty=1, psym=16, color='red', symsize=0.7, $
		ytit='residuals (angstrom)', charsize=0.8, $
		/noerase, position = [0.10, 0.45, 0.95, 0.70], xtickformat="(A1)"
	cgplot, [xra[0], xra[1]], [0,0], /overplot, thick=3, linestyle=2


	; panel 3: plot the spectral resolution
	cgplot, sky_lambda_th, spectral_R, /ynozero, xra=xra, $
		xsty=1, psym=16, color='red', symsize=0.7, $
		xtit='wavelength (micron)', ytit='spectral resolution R', charsize=0.8, $
		/noerase, position = [0.10, 0.20, 0.95, 0.45]
	cgplot, [xra[0], xra[1]], [0,0]+median(spectral_R), /overplot, thick=3, linestyle=2


	; print some stats on wavelength calibration
	cgtext, 0.10, 0.11, 'wavelength calibration residuals: ', /normal, charsize=0.7
	cgtext, 0.10, 0.08, 'standard deviation = ' + $
		cgnumber_formatter( stddev(residuals, /nan), decimals=3) + ' ' + STRING("305B), /normal, charsize=0.7
	cgtext, 0.10, 0.06, 'root mean square = ' + $
		cgnumber_formatter( sqrt( mean(residuals^2, /nan)), decimals=3) + ' ' + STRING("305B), /normal, charsize=0.7
	cgtext, 0.10, 0.04, 'median absolute deviation = ' + $
		cgnumber_formatter( median(abs(residuals)), decimals=3) + ' ' + STRING("305B), /normal, charsize=0.7


	; print some stats on spectral resolution
	cgtext, 0.50, 0.11, 'spectral resolution: ', /normal, charsize=0.7
	cgtext, 0.50, 0.08, 'median R = ' + $
		cgnumber_formatter( median(spectral_R), decimals=0), /normal, charsize=0.7
	cgtext, 0.50, 0.06, 'stddev R = ' + $
		cgnumber_formatter( stddev(spectral_R, /nan), decimals=0), /normal, charsize=0.7


	; print some stats on velocity resolution
	cgtext, 0.75, 0.11, 'median velocity resolution: ', /normal, charsize=0.7
	cgtext, 0.75, 0.08, 'FWHM = ' + $
		cgnumber_formatter( median(3d5/spectral_R), decimals=1) + ' km/s', /normal, charsize=0.7
	cgtext, 0.75, 0.06, 'sigma = ' + $
		cgnumber_formatter( median(3d5/spectral_R)/2.36, decimals=1) + ' km/s', /normal, charsize=0.7


END


;*******************************************************************************
;*******************************************************************************
;*******************************************************************************


PRO flame_checkdata, fuel

	flame_util_module_start, fuel, 'flame_checkdata'

	; calculate diagnostics from reference star
	flame_checkdata_refstar, fuel

	; calculate diagnostics for each slit
	for i_slit=0, n_elements(fuel.slits)-1 do begin

		if fuel.slits[i_slit].skip then continue

		cgPS_open, fuel.util.output_dir + 'slit' + string(fuel.slits[i_slit].number, format='(I02)') + $
			'-' + fuel.slits[i_slit].name +  '_datacheck.ps', /nomatch

		; handle errors by ignoring that slit
		if fuel.settings.stop_on_error eq 0 then begin
			catch, error_status
			if error_status ne 0 then begin
				print, ''
		    print, '**************************'
		    print, '***       WARNING      ***'
		    print, '**************************'
		    print, 'Error found. Skipping slit ' + strtrim(fuel.slits[i_slit].number,2), ' - ', fuel.slits[i_slit].name
				fuel.slits[i_slit].skip = 1
				cgPS_close
				catch, /cancel
				continue
			endif
		endif

		; calculate diagnostics from the sky spectrum
		flame_checkdata_sky, fuel, i_slit=i_slit

		; show result of wavelength calibration on individual frames
		flame_util_check_wavecal, slit=fuel.slits[i_slit], diagnostics=fuel.diagnostics

		cgPS_close

	endfor

	print, ''
	print, 'Outline of slits:'
	for i_slit=0, n_elements(fuel.slits)-1 do $
		print, 'slit ' + string(fuel.slits[i_slit].number, format='(I02)') + ' - ', $
			fuel.slits[i_slit].name, string(9B) + string(9B) + ([' reduced', ' not reduced'])[fuel.slits[i_slit].skip]

	; save fuel structure to output directory
	filename = fuel.util.output_dir + 'fuel.sav'
  save, fuel, filename=filename
  print, 'fuel structure saved to ' + filename


  flame_util_module_end, fuel


END

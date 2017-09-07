;
; Wavelength calibration.
; For each slit & frame, find a polynomial
; warping that describes the 2D transformation from observed frame
; to lambda-calibrated and vertically-rectified frame, using
; the emission line measurements from flame_identify_lines
;

;*******************************************************************************
;*******************************************************************************
;*******************************************************************************

FUNCTION flame_wavecal_gamma, fuel=fuel, slit=slit, this_diagnostics=this_diagnostics
	; return the polynomial coefficients that describe gamma(x,y)

	; first, find the vertical offset to the reference star
	w_this_offset = where(fuel.diagnostics.offset_pos eq this_diagnostics.offset_pos, /null)
	ref_diagnostics = fuel.diagnostics[w_this_offset[0]]
	vertical_offset = this_diagnostics.position - ref_diagnostics.position

	; find the average x coordinate of the reference star trace
	xref = mean(fuel.settings.star_x_range)

	; set the size of the matrix: linear in y, and same degree as slit edge in x
	N_y = 2
	N_x = n_elements(slit.bottom_poly)

	; make the matrix of coefficients
	gamma_coeff = dblarr(N_y, N_x)

	; by definition, dgamma/dy = 1
	gamma_coeff[1,0] = 1.0

	; use the definition of the bottom edge of the slit to build the gamma matrix
	gamma_coeff[0,*] = -slit.bottom_poly

	; but the zero point is such that gamma at xref is the vertical distance to the star trace
	gamma_coeff[0,0] += slit.yrange_cutout[0] - this_diagnostics.position + poly(xref, slit.bottom_poly)

	return, gamma_coeff

END

;*******************************************************************************
;*******************************************************************************
;*******************************************************************************


FUNCTION lambda_calibration, coefficients, speclines=speclines, theoretical_lambdax=theoretical_lambdax, lambda_polyorder=lambda_polyorder
	;
	; This function is used for finding the best-fit coefficients
	; describing the wavelength of each pixel in the observed frame
	;
	; The coefficients are: [P00, P01, P02, P03, P10, P11, P12, P13, P20, ..... PNN]
	; and the lambdax calibration is of the form SUM(Pij*x^i*y^j)
	;

	; check that the total dimension of the coefficients matches the polynomial order
	if n_elements(coefficients) NE (lambda_polyorder[0]+1)*(lambda_polyorder[1]+1) then message, 'dimension of coefficients is wrong!'

	; transform the coefficients from 1D to 2D
	lambda_coeff = reform(coefficients, lambda_polyorder[1]+1, lambda_polyorder[0]+1)

	; given the coefficients, calculate the predicted normalized lambda for each specline
	predicted_lambdax = dblarr(n_elements(speclines))*0.0
	for i=0,lambda_polyorder[0] do for j=0,lambda_polyorder[1] do predicted_lambdax += double(lambda_coeff[j,i]) * double(speclines.x)^i * double(speclines.y)^j

	; construct array with deviation in lambda for each line
	dev = dblarr(n_elements(speclines))

	; different way to calculate dev for the two types of lines
	w_trust = where(speclines.trust_lambda eq 1, /null, compl=w_donttrust)

	; for the lines that can be used for the wavelength calibration,
	; calculate the deviation from the theoretical lambda
	dev[w_trust] = theoretical_lambdax[w_trust] - predicted_lambdax[w_trust]

	; for the lines with unreliable lambda, calculate the relative deviation, i.e. the deviation from the median
	; value of all the other detections of the same line (this helps with the rectification)
	if n_elements(w_donttrust) GT 0 then begin

		; extract a unique list of wavelengths that we should not trust
  	line_lambdas = speclines[w_donttrust].lambda
  	uniq_lambdas = line_lambdas[UNIQ(line_lambdas, SORT(line_lambdas))]

		; for these, calculate the deviation from the median expected lambdax instead of theoretical_lambdax
		uniq_median = uniq_lambdas*0.0
		for i=0, n_elements(uniq_lambdas)-1 do begin
			w_thisline = where(speclines.lambda eq uniq_lambdas[i], /null)
			dev[w_thisline] = predicted_lambdax[w_thisline] - median(predicted_lambdax[w_thisline])
		endfor

	endif

	; return deviation of true lambdax from predicted value
	return, dev

END



;*******************************************************************************
;*******************************************************************************
;*******************************************************************************


PRO flame_wavecal_2D_calibration, fuel=fuel, slit=slit, cutout=cutout, $
		diagnostics=diagnostics, this_diagnostics=this_diagnostics

;
; This routine calculates the 2D wavelength solution and y-rectification.
; These are two mappings from the observed pixel coordinates to the rectified grid
; lambdax, gamma, where lambdax is a pixel grid linear in lambda and gamma is the
; vertical distance to the edge of the slit (taking into account warping and also vertical drift)
; The result of this routine is a pair of coefficient sets, lambda_coeff and gamma_coeff, saved in fuel.slits,
; that can be used to rectify the image
;

	; read in file to calibrate
	im = mrdfits(cutout.filename, 0, header, /silent)

	; read dimensions of the image
	N_imx = (size(im))[1]
	N_imy = (size(im))[2]

	; find the minimum y value for the bottom edge of the slit
	bottom_edge = poly(indgen(N_imx), slit.bottom_poly)
	ymin_edge = min(bottom_edge)

	; this is the y-coordinate of the bottom pixel row in the cutout
	first_pixel = ceil(ymin_edge)

	; get measured speclines
	speclines = *cutout.speclines

	; output lambda axis
	lambda_0 = slit.outlambda_min
	delta_lambda = slit.outlambda_delta

	; translate every detection into the new coordinate system
	theoretical_lambdax = (speclines.lambda - lambda_0)/delta_lambda


	; guess the lambda coefficients -------------------------------------------------------

	; the degrees of the 2D polynomial that describes lambda as a function of (x,y) (plus 1)
	polyorder_x = fuel.settings.wavesolution_order_x
	polyorder_y = fuel.settings.wavesolution_order_y
	if polyorder_x LT 1 or polyorder_x GT 10 then message, 'lambda_polyorder_x is out of range'
	if polyorder_y LT 1 or polyorder_y GT 10 then message, 'lambda_polyorder_y is out of range'

	; guess starting coefficients by fitting a polynomial to the lines at the bottom of the slit
	sorted_y = speclines[sort(speclines.y)].y
	y_threshold = sorted_y[0.1*n_elements(sorted_y)]
	w_tofit = where(speclines.y LE y_threshold, /null)
	guess_coeff1d = robust_poly_fit(speclines[w_tofit].x, (speclines[w_tofit].lambda-slit.outlambda_min)/slit.outlambda_delta, polyorder_x)

	; scale by orders of magnitude for the higher order terms
	starting_coefficients_l = dblarr( polyorder_y+1, polyorder_x+1 )
	for i=0,polyorder_y do starting_coefficients_l[i,*] = guess_coeff1d * (1d-3)^i
	starting_coefficients_l = starting_coefficients_l[*]


	; fit the observed speclines and find the best-fit lambda coefficients --------------------------------------------
	; note that we do the fitting in the lambdax space, with lambdax=0 at lambda_min and lambdax=1 at the next pixel and so on

	; make a copy of all the speclines, before rejection
	speclines_all = speclines

	; number of speclines we are using
	Ngoodpix = n_elements(speclines)+1

	; check that we have enough points to calculate warping polynomial
	if n_elements(speclines) LT 5 then message, 'not enough data points for a wavelength solution'

	; loops are used to throw away outliers and make the fit more robust
	WHILE n_elements(speclines) LT Ngoodpix AND n_elements(speclines) GE 5 DO BEGIN

		; save old number of good speclines
		Ngoodpix = n_elements(speclines)

		args = {speclines:speclines, theoretical_lambdax:theoretical_lambdax, lambda_polyorder:[polyorder_x, polyorder_y] }

		; fit the data and find the coefficients for the lambda calibration
		lambdax_coeff1d = mpfit('lambda_calibration', starting_coefficients_l, functargs=args, $
			bestnorm=bestnorm_l, best_resid=best_resid, /quiet, status=status_l)

		; check that mpfit worked
		if status_l LE 0 then message, 'mpfit did not find a good solution'

		w_outliers = where( abs(best_resid) GT 3.0*stddev(best_resid), complement=w_goodpix, /null)
		print, strtrim( n_elements(w_outliers), 2) + ' outliers rejected. ', format='(a,$)'

		; keep only the non-outliers
		speclines = speclines[w_goodpix]
		theoretical_lambdax = theoretical_lambdax[w_goodpix]

	ENDWHILE

	; -------------------------------------------------------
	; plot the individual detections on a 2D view of the slit
	cgplot, speclines_all.x, speclines_all.y, psym=16, xtit='x pixel', ytitle='y pixel in this cutout', $
	title='emission line detections', charsize=1, layout=[1,2,1], symsize=0.5, color='red5'

	; these are the speclines that were not rejected
	cgplot, speclines.x, speclines.y, psym=16, symsize=0.6, /overplot

	; show the line widths
	cgplot, speclines_all.x, speclines_all.sigma, psym=16, xtit='x pixel', ytitle='line width (pixel)', $
	charsize=1, layout=[1,2,2], symsize=0.5, yra=[ min(speclines_all.sigma), max(speclines_all.sigma) ], /ysty, color='red5'

	; these are the speclines that were not rejected
	cgplot, speclines.x, speclines.sigma, psym=16, symsize=0.6, /overplot

	; mark the median value
	cgplot, [0, 2*max(speclines_all.x)], median(speclines_all.sigma) + [0,0], /overplot, thick=3, linestyle=2


	; -------------------------------------------------------
	; plot the residuals of the wavelength solution

	; first we need to calculate the residuals for the full list of speclines, including the rejected ones
	best_resid_all = lambda_calibration(lambdax_coeff1d, speclines=speclines_all, $
		theoretical_lambdax=(speclines_all.lambda - lambda_0)/delta_lambda, lambda_polyorder=[polyorder_x, polyorder_y])

	; show the residuals
	cgplot, speclines_all.x, best_resid_all*delta_lambda*1d4, psym=16, $
		xtit='x pixel', ytitle='delta lambda (angstrom)', $
		title='Residuals of the wavelength solution (stddev: ' + $
			cgnumber_formatter( stddev( best_resid*delta_lambda*1d4, /nan), decimals=3) + $
			' angstrom)', charsize=1, thick=3, symsize=0.5, color='red5'

	; these are the speclines that were not rejected
	cgplot, speclines.x, best_resid*delta_lambda*1d4, psym=16, symsize=0.6, /overplot

	; mark the zero
	cgplot, [0, 2*max(speclines_all.x)], [0,0], /overplot, thick=3, linestyle=2

	; -------------------------------------------------------

	; convert the coefficients to a 2D matrix
	lambdax_coeff = reform(lambdax_coeff1d, polyorder_y+1, polyorder_x+1)

	; convert from lambdax to lambda
	lambda_coeff = lambdax_coeff * delta_lambda
	lambda_coeff[0,0] = lambda_coeff[0,0] + lambda_0


	; find the gamma coefficients -------------------------------------------------------

	gamma_coeff = flame_wavecal_gamma(fuel=fuel, slit=slit, this_diagnostics=this_diagnostics)


	; save and output -------------------------------------------------------

	; save into slit structure
	*cutout.lambda_coeff = lambda_coeff
	*cutout.gamma_coeff = gamma_coeff

	; finally, output the actual wavelength calibration as a 2D array

	; create empty frame that will contain the wavelength solution
	wavelength_solution = im * 0.0

	; apply the polynomial transformation to calculate (lambda, gamma) at each point of the 2D grid
	for ix=0, N_imx-1 do $
		for iy=0, N_imy-1 do begin
			wavelength_solution[ix, iy] = flame_util_transform_coord(ix, iy, *cutout.lambda_coeff )
		endfor

	; write the accurate solution to a FITS file
	writefits, flame_util_replace_string(cutout.filename, '.fits', '_wavecal_2D.fits'), wavelength_solution, hdr


END


;*******************************************************************************
;*******************************************************************************
;*******************************************************************************



PRO flame_wavecal_2D_calibration_witharcs, fuel=fuel, slit=slit, cutout=cutout, $
		diagnostics=diagnostics, this_diagnostics=this_diagnostics
;
; Use the rectification obtained from the arcs, calculate and apply the horizontal and
; vertical shift, and copy to science frame
;

	; rectify and extract the sky spectrum
	; --------------------------------------------------

	; read in slit
	im = mrdfits(cutout.filename, 0, hdr, /silent)

	; read dimensions of the observed frame
	N_imx = (size(im))[1]
	N_imy = (size(im))[2]

	; create 2D arrays containing the observed coordinates of each pixel
	x_2d = indgen(N_imx) # replicate(1, N_imy)
	y_2d = replicate(1, N_imx) # indgen(N_imy)

	; create 2D arrays containing the rectified coordinates of each pixel
	lambda_2d = flame_util_transform_coord(x_2d, y_2d, *slit.arc_cutout.lambda_coeff )
	gamma_2d = flame_util_transform_coord(x_2d, y_2d, *slit.arc_cutout.gamma_coeff )

	; get the parameters for the output grid
	lambda_0 = slit.outlambda_min
	delta_lambda = slit.outlambda_delta
	Nx = slit.outlambda_Npix

	; normalize the lambda values (otherwise triangulate does not work well; maybe because the scale of x and y is too different)
	lambdax_2d = (lambda_2d-lambda_0) / delta_lambda

	; find the range of gamma values in the image
	gamma_min = round( min(gamma_2d, /nan) )
	gamma_max = round( max(gamma_2d, /nan) )
	Ny = gamma_max-gamma_min

	; resample image onto new grid using griddata
	triangulate, lambdax_2d, gamma_2d, triangles
	new_im = griddata(lambdax_2d, gamma_2d, im, triangles=triangles, start=[0.0, gamma_min], delta=[1.0, 1.0], dimension=[Nx, Ny], /linear, missing=!values.d_nan)

	; now stack the rectified image into a 1D spectrum
	spec1d = median(new_im, dimension=2)

	; make the 1D lambda axis
	lambda1d = lambda_0 + delta_lambda * dindgen(Nx)


	; cross-correlate sky spectrum for zero-th order shift
	; --------------------------------------------------

  ; load the model sky spectrum, to be used as a reference
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

	; normalize both model and observed spectrum
	model_flux_resampled /= median(model_flux_resampled)
	spec1d_clean /= median(spec1d_clean)

  ; measure the overall shift between observed and model spectrum
  lag = indgen(100)-50 ; up to 50 pixels each direction
  crosscorr = c_correlate( spec1d_clean, model_flux_resampled, lag)
  max_crosscorr = max( crosscorr, max_ind, /nan)
  delta = -lag[max_ind] * delta_lambda	; this is the overall shift in wavelength obtained by the cross-correlation


	; fit sky lines
	; --------------------------------------------------

  ; load line list
	readcol, fuel.settings.linelist_filename, line_list, line_trust, format='D,I', /silent

	; use only the lines in the right range and with a wavelength that we can trust
	line_list = line_list[where( line_list GT lambda1d[0] and line_list LT lambda1d[-1] and line_trust gt 0, /null)]

	; estimate the FWHM of sky lines
	fwhm_lambda = median(lambda1d) / slit.approx_R

	; empty arrays that will have the results
	line_th = []
	line_meas = []
	line_width = []

	; fit each of the sky lines
	for i_line=0, n_elements(line_list)-1 do begin

		; the expected wavelength of this line, accounting for overall shift
		line_exp = line_list[i_line] + delta

		; select the region to fit - +/- 3 FWHM
		w_fit = where( abs(lambda1d-line_exp) LT 3.0*fwhm_lambda, /null )

		; check that the region is within the observed range
		if w_fit eq !NULL then continue

    ; check that there actually is signal and it's not just a bunch of NaNs
    if n_elements( where( finite(spec1d[w_fit]), /null ) ) LE 5 then continue

		; estimate parameters of the Gaussian
		est_peak = max( median( spec1d[w_fit], 3) , /nan)
		est_center = line_exp
		est_sigma = fwhm_lambda/2.36
		est_cont = min( median( spec1d[w_fit], 3) , /nan)

		; Gaussian fit
		!NULL = gaussfit( lambda1d[w_fit], spec1d[w_fit], gauss_param, nterms=4, $
			estimates=[est_peak, est_center, est_sigma, est_cont], sigma=gauss_err, chisq=chisq )

		; check that chi square makes sense
		if ~finite(chisq) then continue

		; check that the peak of the Gaussian is positive
		if gauss_param[0] LT 0.0 then continue

		; check that the SNR is high
		if gauss_param[0] LT 5.0*gauss_err[0] then continue

		; check that the center of the Guassian is in the observed range
		if gauss_param[1] LT min(lambda1d[w_fit]) or gauss_param[1] GT max(lambda1d[w_fit]) then continue

		; check that the Gaussian width makes sense
		if gauss_param[2] LT fwhm_lambda/10.0 or gauss_param[2] GT fwhm_lambda*10.0 then continue

		; save the result of the fit
		line_th = [line_th, line_list[i_line]]
		line_meas = [line_meas, gauss_param[1]]
		line_width = [line_width, gauss_param[2]]

	endfor


	; check if sky lines were found
	; --------------------------------------------------

	if n_elements(line_meas) GE fuel.settings.shift_arcs_Nmin_lines then begin

		; make plots
		; --------------------------------------------------

		; charsize
		ch = 0.8

		; panel 1: plot the spectrum
		erase
		cgplot, lambda1d, spec1d, charsize=ch, xsty=1, xtit='', ytit='observed flux', title='measuring shift between sky lines and arcs wavelength solution', $
			position = [0.15, 0.65, 0.95, 0.96], xtickformat="(A1)", xra=[lambda1d[0], lambda1d[-1]], /nodata

		; show the sky lines that were identified
		for i_line=0, n_elements(line_meas)-1 do cgplot, line_meas[i_line] + [0,0], [-2,2]*max(abs(spec1d)), /overplot, color='red'

		; show the spectrum on top, for clarity
		cgplot, lambda1d, spec1d, /overplot


		; panel 2: show the residuals
		cgplot, line_meas, 1d4 * (line_meas-line_th), /ynozero, xra=[lambda1d[0], lambda1d[-1]], xsty=1, psym=16, color='red', symsize=0.7, $
			ytit='residuals (' + string("305B) + ')', charsize=ch, $
			/noerase, position = [0.15, 0.35, 0.95, 0.65], xtickformat="(A1)"

	  cgplot, [lambda1d[0], lambda1d[-1]], [0,0], /overplot, thick=2

		; show median value of residuals
		cgplot, [lambda1d[0], lambda1d[-1]], [0,0]+median(line_meas-line_th)*1d4, /overplot, thick=3, linestyle=2


		; panel 3: plot the line widths
		cgplot, line_meas, line_width*1d4, /ynozero, xra=[lambda1d[0], lambda1d[-1]], xsty=1, psym=16, color='red', symsize=0.7, $
			xtit='wavelength (micron)', ytit='line width (' + string("305B) + ')', charsize=ch, $
			/noerase, position = [0.15, 0.10, 0.95, 0.35]

		; show median value of line width
		cgplot, [lambda1d[0], lambda1d[-1]], [0,0]+median(line_width)*1d4, /overplot, thick=3, linestyle=2

		; take the median shift
		lambda_shift = median(line_meas-line_th)
		print, 'The median shift between this frame and the arcs frame is ', lambda_shift*1d4, ' angstrom'


	endif else begin

		; use the sky continuum for calculating the shift
		; --------------------------------------------------

		print, ''
		print, 'Could not find enough sky lines to shift the wavelength solution!'
		print, 'The shift of the wavelength solution will be derived from the sky continuum'

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
		  delta = -lag[max_ind] * delta_lambda/10.0

			; show the shifted spectra
			cgplot, bin_lambda_up, bin_model_up, color='red', thick=3, xtit='wavelength (micron)', $
				title='cross-correlation of observed vs model sky', charsize=1, /ynozero
			cgplot, bin_lambda_up, shift(bin_obs_up, lag[max_ind]), thick=2, /overplot

			; save the result
			shift_x = [shift_x, mean(bin_lambda_up)]
			shift_y = [shift_y, delta]

		endfor

		; this is the final shift
		lambda_shift = median(shift_y)

		cgplot, shift_x, shift_y*1d4, psym=-16, charsize=1, xtit='wavelength (micron)', ytit='wavelength shift (angstrom)'
		cgplot, [-1, 2*shift_x[-1]], [0,0]+lambda_shift*1d4, /overplot, linestyle=2

		print, 'The median shift between this frame and the arcs frame is ', lambda_shift*1d4, ' angstrom'


	endelse


	; apply shift to rectification
	; --------------------------------------------------

	; start with the rectification form the arcs
	lambda_coeff = *slit.arc_cutout.lambda_coeff

	; apply a constant wavelength shift
	lambda_coeff[0,0] = lambda_coeff[0,0] - lambda_shift


	; find the gamma coefficients -------------------------------------------------------

	gamma_coeff = flame_wavecal_gamma(fuel=fuel, slit=slit, this_diagnostics=this_diagnostics)


	; save into slit structure
	*cutout.lambda_coeff = lambda_coeff
	*cutout.gamma_coeff = gamma_coeff

	; finally, output the actual wavelength calibration as a 2D array

	; create empty frame that will contain the wavelength solution
	wavelength_solution = im * 0.0

	; apply the polynomial transformation to calculate (lambda, gamma) at each point of the 2D grid
	for ix=0, N_imx-1 do $
		for iy=0, N_imy-1 do $
			wavelength_solution[ix, iy] = flame_util_transform_coord(ix, iy, *cutout.lambda_coeff )

	; write the accurate solution to a FITS file
	writefits, flame_util_replace_string(cutout.filename, '.fits', '_wavecal_2D.fits'), wavelength_solution, hdr


END



;*******************************************************************************
;*******************************************************************************
;*******************************************************************************



PRO flame_wavecal_illum_correction, fuel=fuel, i_slit=i_slit, i_frame=i_frame
	;
	; use the speclines to derive and apply an illumination correction
	; along the spatial slit axis
	;

	cutout = fuel.slits[i_slit].cutouts[i_frame]
	speclines = *cutout.speclines

	; read in slit
	im = mrdfits(cutout.filename, 0, hdr, /silent)
	im_sigma = mrdfits(cutout.filename, 1, /silent)

	; cutout dimensions
	N_pixel_x = (size(im))[1]
	N_pixel_y = (size(im))[2]

	; sort by wavelength
	sorted_lambdas = speclines[ sort(speclines.lambda) ].lambda

	; find unique wavelengths
	lambdas = sorted_lambdas[uniq(sorted_lambdas)]

	; calculate Gussian fluxes
	OHflux = sqrt(2.0*3.14) * speclines.peak * speclines.sigma

	; for each line, normalize flux to the median
	OHnorm = OHflux * 0.0
	for i_line=0, n_elements(lambdas)-1 do begin
		w_thisline = where(speclines.lambda eq lambdas[i_line], /null)
		OHnorm[w_thisline] = OHflux[w_thisline] / median(OHflux[w_thisline])
	endfor

	; calculate the gamma coordinate of each OHline detection
	OHlambda = flame_util_transform_coord(speclines.x, speclines.y, *cutout.lambda_coeff )
	OHgamma = flame_util_transform_coord(speclines.x, speclines.y, *cutout.gamma_coeff )

	; sort by gamma
	sorted_gamma = OHgamma[sort(OHgamma)]
	sorted_illum = OHnorm[sort(OHgamma)]

	; do not consider measurements that are more than a factor of three off
	w_tofit = where(sorted_illum GT 0.33 and sorted_illum LT 3.0, /null)

	; set the boundaries for a meaningful correction
	gamma_min = sorted_gamma[3]
	gamma_max = sorted_gamma[-4]

	; fit polynomial to the illumination correction as a function of gamma
	; NB: to increase robustness, set zero-point for gamma so that we are working with small numbers
	poly_coeff = robust_poly_fit(sorted_gamma[w_tofit]-gamma_min, sorted_illum[w_tofit], 8)

	; scatter plot of the illumination (show all OH lines)
	cgplot, sorted_gamma[w_tofit], sorted_illum[w_tofit], psym=3, /ynozero, charsize=1.2, $
		xtitle='gamma coordinate', ytitle='Illumination'

	; overplot the smooth illumination
	x_axis = gamma_min + (gamma_max-gamma_min)*dindgen(200)/199.
	cgplot, x_axis, poly(x_axis-gamma_min, poly_coeff), $
		/overplot, color='red', thick=3

	if median(poly(x_axis-gamma_min, poly_coeff)) GT 2.0 or $
		median(poly(x_axis-gamma_min, poly_coeff)) LT 0.5 then message, 'Illumination correction failed'

	; overplot flat illumination
	cgplot, [gamma_min - 0.5*gamma_max , gamma_max*1.5], [1,1], /overplot, linestyle=2, thick=3

	; overplot the limit to the correction (25%)
	cgplot, [gamma_min - 0.5*gamma_max , gamma_max*1.5], 0.75+[0,0], /overplot, linestyle=2, thick=1
	cgplot, [gamma_min - 0.5*gamma_max , gamma_max*1.5], 1.25+[0,0], /overplot, linestyle=2, thick=1

	; if we do not have to apply the illumination correction, then we are done
	if ~fuel.settings.illumination_correction then return

	; calculate the gamma coordinate for each observed pixel, row by row
	gamma_coordinate = im * 0.0
	for i_row=0, N_pixel_y-1 do gamma_coordinate[*,i_row] = $
		flame_util_transform_coord(dindgen(N_pixel_x), replicate(i_row, N_pixel_x), *cutout.gamma_coeff )

	; calculate the illumination correction at each pixel
	illumination_correction = poly(gamma_coordinate-gamma_min, poly_coeff)

	; set the correction to NaN when outside the boundary
	illumination_correction[where(gamma_coordinate LT gamma_min OR $
		gamma_coordinate GT gamma_max, /null)] = !values.d_NaN

	; set the correction to NaN if it's more than 25%
	illumination_correction[where(illumination_correction GT 1.25 or $
		illumination_correction LT 0.75, /null)] = !values.d_NaN

	; apply illumination correction
	im /= illumination_correction
	im_sigma /= illumination_correction

	; filename for the illumination-corrected cutout
	illcorr_filename = flame_util_replace_string(cutout.filename, '_corr', '_illcorr')

	; write out the illumination-corrected cutout
  writefits, illcorr_filename, im, hdr
	writefits, illcorr_filename, im_sigma, /append

	; update the flag
	fuel.slits[i_slit].cutouts[i_frame].illcorr_applied = 1


END


;*******************************************************************************
;*******************************************************************************
;*******************************************************************************



PRO flame_wavecal_accurate, fuel

	flame_util_module_start, fuel, 'flame_wavecal_accurate'


	; loop through all slits
	for i_slit=0, n_elements(fuel.slits)-1 do begin

		; this slit
		this_slit = fuel.slits[i_slit]

		if this_slit.skip then continue

	  print, 'Accurate wavelength calibration for slit ', strtrim(this_slit.number,2), ' - ', this_slit.name
		print, ' '

		; handle errors by ignoring that slit
		if fuel.settings.debugging eq 0 then begin
			catch, error_status
			if error_status ne 0 then begin
				print, ''
		    print, '**************************'
		    print, '***       WARNING      ***'
		    print, '**************************'
		    print, 'Error found. Skipping slit ' + strtrim(this_slit.number,2), ' - ', this_slit.name
				fuel.slits[i_slit].skip = 1
				catch, /cancel
				continue
			endif
		endif


		if fuel.util.arc.n_frames GT 0 then begin

				; the speclines measured for this slit
				arc_speclines = *this_slit.arc_cutout.speclines

				; calculate the polynomial transformation between observed and rectified frame, for the arcs
				cgPS_open, flame_util_replace_string(fuel.slits[i_slit].arc_cutout.filename, '.fits', '_wavecal.ps'), /nomatch
				flame_wavecal_2D_calibration, fuel=fuel, slit=this_slit, cutout=this_slit.arc_cutout, $
					diagnostics=fuel.diagnostics, this_diagnostics=(fuel.diagnostics)[0] 	; assume the dithering of the first frame
				cgPS_close

		endif


		for i_frame=0, n_elements(fuel.slits[i_slit].cutouts)-1 do begin

				print, ''

				; the speclines measured for this slit
				speclines = *this_slit.cutouts[i_frame].speclines

				cgPS_open, flame_util_replace_string(fuel.slits[i_slit].cutouts[i_frame].filename, '.fits', '_wavecal.ps'), /nomatch

				if fuel.util.arc.n_frames GT 0 then begin

					; copy the arc wavelength solution to all cutouts
					*fuel.slits[i_slit].cutouts[i_frame].lambda_coeff = *fuel.slits[i_slit].arc_cutout.lambda_coeff

					; use the arcs wavelength solution, find a wavelength shift, and save to current frame
					flame_wavecal_2D_calibration_witharcs, fuel=fuel, slit=this_slit, cutout=this_slit.cutouts[i_frame], $
						diagnostics=fuel.diagnostics, this_diagnostics=(fuel.diagnostics)[i_frame]

				endif else begin

					; calculate the polynomial transformation between observed and rectified frame
					flame_wavecal_2D_calibration, fuel=fuel, slit=this_slit, cutout=this_slit.cutouts[i_frame], $
						diagnostics=fuel.diagnostics, this_diagnostics=(fuel.diagnostics)[i_frame]

					; calculate and apply the illumination correction
					flame_wavecal_illum_correction, fuel=fuel, i_slit=i_slit, i_frame=i_frame

				endelse

				cgPS_close



		endfor

	endfor


  flame_util_module_end, fuel

END

# -*- coding: utf-8 -*-
"""Translate a solution file in static format, to a solution file in FSP format
"""


import numpy as np
import json
from obspy.geodetics import flinnengdahl
import plane_management as pl_mng
import get_outputs
import datetime
import os
import seismic_tensor as tensor
import fault_plane as pf


def static_to_fsp(tensor_info, segments_data, used_data, vel_model, solution):
    """Write FSP file with the solution of FFM modelling from file Solucion.txt

    :param tensor_info: dictionary with moment tensor information
    :param segments_data: list of dictionaries with properties of fault segments
    :param used_data: list with data types to be used in modelling
    :param solution: dictionary with output kinematic model properties
    :param vel_model: dictionary with velocity model properties
    :type tensor_info: dict
    :type segments_data: list
    :type used_data: list
    :type solution: dict
    :type vel_model: dict
    """
    locator = flinnengdahl.FlinnEngdahl()
    segments = segments_data['segments']
    rise_time = segments_data['rise_time']
    point_sources = pf.point_sources_param(segments, tensor_info, rise_time)
    delta_strike = segments[0]['delta_strike']
    delta_dip = segments[0]['delta_dip']
    rupture_vel = segments[0]['rupture_vel']
    subfaults = {'delta_strike': delta_strike, 'delta_dip': delta_dip}
    subfaults2 = pf._point_sources_def(rise_time, rupture_vel, subfaults)
    strike_ps = int(subfaults2['strike_ps'] / 2)
    dip_ps = int(subfaults2['dip_ps'] / 2)
    slips = solution['slip']
    rakes = solution['rake']
    trup = solution['rupture_time']
    trise = solution['trise']
    tfall = solution['tfall']
    # depths = solution['depth']
    moment = solution['moment']
    total_moment = 0
    for moment_segment in moment:
        total_moment = total_moment + np.sum(np.array(moment_segment).flatten())

    string = ' ---------------------------------- '
    event_lat = tensor_info['lat']
    event_lon = tensor_info['lon']
    depth = tensor_info['depth']
    moment_mag = 2 * np.log10(total_moment) / 3 - 10.7
    location = locator.get_region(event_lon, event_lat)
    date = tensor_info['datetime']
    tag = date
    now = datetime.datetime.now()

    plane_info = segments[0]
    stk_subfaults, dip_subfaults, delta_strike, delta_dip, hyp_stk, hyp_dip\
        = pl_mng.__unpack_plane_data(plane_info)
    hyp_stk = (hyp_stk + 0.5) * delta_strike
    length = delta_strike * stk_subfaults
    hyp_dip = (hyp_dip + 0.5) * delta_dip
    width = delta_dip * dip_subfaults
    strike = plane_info['strike']
    dip = plane_info['dip']
    rake = plane_info['rake']
    latitudes = [ps_segment[:, :, dip_ps, strike_ps, 0] for ps_segment in point_sources]
    longitudes = [ps_segment[:, :, dip_ps, strike_ps, 1] for ps_segment in point_sources]
    depths = [ps_segment[:, :, dip_ps, strike_ps, 2] for ps_segment in point_sources]
    ps_depths = [ps_segment[:, :, :, :, 2] for ps_segment in point_sources]
    min_depth = min([np.min(ps_depth.flatten()) for ps_depth in ps_depths])
    ps_distances = [ps_segment[:, :, dip_ps, strike_ps, 3] for ps_segment in point_sources]
    ps_times = [ps_segment[:, :, dip_ps, strike_ps, 4] for ps_segment in point_sources]
    delta_time = [rupt_seg - ps_time for ps_time, rupt_seg\
        in zip(ps_times, trup)]
    total_subfaults = [segment['stk_subfaults'] * segment['dip_subfaults']\
        for segment in segments]
    total_subfaults = np.sum(np.array(total_subfaults))
    avg_time1 = [np.sum(trise_seg.flatten()) for trise_seg in trise]
    avg_time1 = np.sum(np.array(avg_time1).flatten()) / total_subfaults
    avg_time2 = [np.sum(tfall_seg.flatten()) for tfall_seg in tfall]
    avg_time2 = np.sum(np.array(avg_time2).flatten()) / total_subfaults
    avg_time = avg_time1 + avg_time2
    avg_vel = [ps_dist / rupt_seg for ps_dist, rupt_seg\
        in zip(ps_distances, trup)]
    avg_vel = [np.where(np.isnan(avg_vel_seg), 0, avg_vel_seg) for avg_vel_seg in avg_vel]
    avg_vel = [np.sum(avg_vel_seg.flatten()) for avg_vel_seg in avg_vel]
    avg_vel = np.sum(np.array(avg_vel).flatten()) / total_subfaults
    min_rise = rise_time['min_rise']
    delta_rise = rise_time['delta_rise']
    windows = rise_time['windows']

    quantity_strong = 0
    if 'strong_motion' in used_data:
        strong_data = json.load(open('strong_motion_waves.json'))
        quantity_strong = len(strong_data)
    quantity_gps = 0
    if 'gps' in used_data:
        gps_data = json.load(open('static_data.json'))
        quantity_gps = len(gps_data)
    quantity_tele = 0
    if 'tele_body' in used_data:
        tele_data = json.load(open('tele_waves.json'))
        quantity_tele = len(tele_data)
    quantity_surf = 0
    if 'surf_tele' in used_data:
        surf_data = json.load(open('surf_waves.json'))
        quantity_surf = len(surf_data)

    n_layers = len(vel_model['dens'])
    p_vel = [float(v) for v in vel_model['p_vel']]
    s_vel = [float(v) for v in vel_model['s_vel']]
    dens = [float(v) for v in vel_model['dens']]
    thick = [float(v) for v in vel_model['thick']]
    qp = [float(v) for v in vel_model['qa']]
    qs = [float(v) for v in vel_model['qb']]
    depth2 = np.cumsum(np.array(thick))
    depth2 = np.concatenate([[0], depth2])# - depth2[0]
    zipped = zip(depth2, p_vel, s_vel, dens, qp, qs)
    zipped2 = zip(segments, point_sources, latitudes, longitudes,
                  depths, slips, rakes, trup, trise, tfall, moment)

    string2 = '{0:9.4f} {1:9.4f} {2:9.4f} {3:9.4f} {4:9.4f} '\
        '{5:8.4f} {6:9.4f} {7:8.4f} {8:9.4f}  {9:8.2e}\n'
    string_fun = lambda a, b, c, d, e, f, g, h, i, j:\
        string2.format(a, b, c, d, e, f, g, h, i, j)

    with open('fsp_sol_file.txt', 'w') as outfile:
        outfile.write('%{}FINITE-SOURCE RUPTURE '\
            'MODEL{}\n%\n'.format(string, string))
        outfile.write('% Event : {} {} CSN\n'.format(location, date))
        outfile.write('% EventTAG: {}\n%\n'.format(tag))
        outfile.write('% Loc  : LAT = {}  LON = {}  DEP = {}\n'.format(
            event_lat, event_lon, depth))
        outfile.write(
            '% Size : LEN = {} km  WID = {} km  Mw = {}  Mo = {} Nm\n'.format(
                length, width, moment_mag, total_moment * 10 ** -7))
        outfile.write(
            '% Mech : STRK = {} DIP = {} RAKE = {}  Htop = {} '\
            'km\n'.format(strike, dip, rake, min_depth))
        outfile.write(
            '% Rupt : HypX = {} km  Hypz = {} km  avTr = {:5.2f} s  avVr = {:5.2f} '\
            'km/s\n%\n'.format(hyp_stk, hyp_dip, avg_time, avg_vel))
        outfile.write('% {} inversion-related '\
            'parameters{}\n'.format(string, string))
        outfile.write('%\n% Invs : Nx = {}  Nz = {} Fmin = {} Hz  '\
            'Fmax = {} Hz\n'.format(stk_subfaults, dip_subfaults, 0.01, 0.125))
        outfile.write('% Invs : Dx = {} km  Dz = {} '\
            'km\n'.format(delta_strike, delta_dip))
        outfile.write('% Invs : Ntw = {}  Nsg = {}     '\
            '(# of time-windows,# of fault segments)'\
            '\n'.format(windows, len(segments)))
        outfile.write('% Invs : LEN = {} s SHF = {} s    '\
            '(time-window length and time-shift)\n'.format(
                min_rise + delta_rise, delta_rise))
        outfile.write('% SVF  : Asymetriccosine    '\
            '(type of slip-velocity function used)\n')
        outfile.write('%\n% Data : SGM TELE TRIL LEVEL GPS INSAR SURF OTHER\n')
        outfile.write('% Data : {} {} 0 0 {} 0 {} '\
            '0\n'.format(quantity_strong, quantity_tele, quantity_gps,
                         quantity_surf))
        outfile.write('% Data : {} {} 0 0 {} 0 {} '\
            '0\n'.format(quantity_strong, quantity_tele, quantity_gps,
                         quantity_surf))
        outfile.write('% Data : {} {} 0 0 {} 0 {} '\
            '0\n'.format(quantity_strong, quantity_tele, quantity_gps,
                         quantity_surf))
        outfile.write('%\n%{}{}\n'.format(string, string))
        outfile.write('%\n% VELOCITY-DENSITY STRUCTURE\n')
        outfile.write('% No. of layers = {}\n'.format(n_layers))
        outfile.write('%\n% DEPTH P_VEL S_VEL DENS QP QS\n')
        outfile.write('% [km] [km/s] [km/s] [g/cm^3]\n')
        for dep, pv, sv, den, qpp, qss in zipped:
            outfile.write('% {} {} {} {}  {}  '\
            '{}\n'.format(dep, pv, sv, den, qpp, qss))
        outfile.write('%\n%{}{}\n'.format(string, string))
        outfile.write('% {}/{}/{} created by degoldberg@usgs.gov'\
        'cl\n'.format(now.day, now.month, now.year))
        outfile.write('%\n% SOURCE MODEL PARAMETERS\n')
        if len(segments) == 1:
            outfile.write('% Nsbfs = {} subfaults\n'.format(stk_subfaults, dip_subfaults))
        outfile.write('% X,Y,Z coordinates in km; SLIP in m\n')
        outfile.write('% if applicable: RAKE in deg, RISE in s, TRUP in s, '\
            'slip in each TW in m\n')
        outfile.write('%\n% Coordinates are given for center of each '\
            'subfault or segment: |\'|\n')
        outfile.write('% Origin of local coordinate system at epicenter: '\
            'X (EW) = 0, Y (NS) = 0\n')
        if len(segments) == 1:
            outfile.write('% LAT LON X==EW Y==NS Z SLIP RAKE TRUP RISE ')
            outfile.write('SF_MOMENT\n%{}{}\n'.format(string, string))
            lat_fault = latitudes[0].flatten()
            lon_fault = longitudes[0].flatten()
            depth_fault = depths[0].flatten()
            slip_fault = slips[0].flatten()
            rake_fault = rakes[0].flatten()
            trup_fault = trup[0].flatten()
            trise_fault = trise[0].flatten()
            tfall_fault = tfall[0].flatten()
            moment_fault = moment[0].flatten()
            zipped3 = zip(lat_fault, lon_fault, depth_fault, slip_fault,
                          rake_fault, trup_fault, trise_fault, tfall_fault,
                          moment_fault)
            for line in zipped3:
                lat, lon, dep, slip, rake, t_rup, t_ris, t_fal, moment = line
                north_south = (float(lat) - event_lat) * 111.11
                east_west = (float(lon) - event_lon) * 111.11
                moment = moment * 10 ** -7
                slip = slip * 10 ** -2
                outfile.write(
                    string_fun(lat, lon, east_west, north_south, dep,
                               slip, rake, t_rup, t_ris + t_fal, moment))
        else:
            outfile.write('%{}{}\n'.format(string, string))
            outfile.write('%{} MULTISEGMENT MODEL {}\n'.format(string, string))
            outfile.write('%{}{}\n'.format(string, string))
            start_line = 10
            for i_segment, fault_segment_data in enumerate(zipped2):
                segment = fault_segment_data[0]
                ps_seg = fault_segment_data[1]
                lat_fault = fault_segment_data[2].flatten()
                lon_fault = fault_segment_data[3].flatten()
                depth_fault = fault_segment_data[4].flatten()
                slip_fault = fault_segment_data[5].flatten()
                rake_fault = fault_segment_data[6].flatten()
                trup_fault = fault_segment_data[7].flatten()
                trise_fault = fault_segment_data[8].flatten()
                tfall_fault = fault_segment_data[9].flatten()
                moment_fault = fault_segment_data[10].flatten()
                strike = segment['strike']
                dip = segment['dip']
                stk_subfaults, dip_subfaults, delta_strike, delta_dip, hyp_stk, hyp_dip\
                    = pl_mng.__unpack_plane_data(plane_info)
                length = stk_subfaults * delta_strike
                width = dip_subfaults * delta_dip
                min_dep = np.min(ps_seg[:, :, :, :, 2].flatten())
                lat0 = ps_seg[-1, -1, -1, -1, 0]
                lon0 = ps_seg[-1, -1, -1, -1, 1]
                hyp_stk = (hyp_stk + 0.5) * delta_strike
                hyp_dip = (hyp_dip + 0.5) * delta_dip
                n_subfaults = stk_subfaults * dip_subfaults
                outfile.write('% SEGMENT # {}: STRIKE = {} deg DIP = {} '\
                    'deg\n'.format(i_segment + 1, strike, dip))
                outfile.write('% LEN = {} km WID = {} km\n'.format(length, width))
                outfile.write('% depth to top: Z2top = {:6.2f} km\n'.format(min_dep))
                outfile.write('% coordinates of top-center\n')
                outfile.write('% LAT = {}, LON = {}\n'.format(lat0, lon0))
                outfile.write('% hypocenter on SEG # {} : along-strike (X) '\
                    '= {}, down-dip (Z) = {}\n'.format(
                    i_segment + 1, hyp_stk, hyp_dip))
                outfile.write('% Nsbfs = {} subfaults\n'.format(n_subfaults))
                outfile.write('% LAT LON X==EW Y==NS Z SLIP RAKE TRUP RISE ')
                outfile.write('SF_MOMENT\n%{}{}\n'.format(string, string))
                zipped3 = zip(lat_fault, lon_fault, depth_fault, slip_fault,
                              rake_fault, trup_fault, trise_fault, tfall_fault,
                              moment_fault)
                for line in zipped3:
                    lat, lon, dep, slip, rake, t_rup, t_ris, t_fal,\
                    moment = line
                    north_south = (float(lat) - event_lat) * 111.11
                    east_west = (float(lon) - event_lon) * 111.11
                    moment = moment * 10 ** -7
                    slip = slip * 10 ** -2
                    outfile.write(
                        string_fun(lat, lon, east_west, north_south, dep,
                                   slip, rake, t_rup, t_ris + t_fal, moment))
                    start_line = start_line + 1
                start_line = start_line + 9


if __name__ == '__main__':
    import argparse
    import errno

    parser = argparse.ArgumentParser()
    parser.add_argument("-f", "--folder", default=os.getcwd(),
                        help="folder where there are input files")
    parser.add_argument("-gcmt", "--gcmt_tensor",
                        help="location of GCMT moment tensor file")
    parser.add_argument("-v", "--velmodel",
                        help="direction of velocity model file")
    parser.add_argument("-t", "--tele", action="store_true",
                        help="use teleseismic data in modelling")
    parser.add_argument("-su", "--surface", action="store_true",
                        help="use surface waves data in modelling")
    parser.add_argument("-st", "--strong", action="store_true",
                        help="use strong motion data in modelling")
    parser.add_argument("--cgps", action="store_true",
                        help="use cGPS data in modelling")
    parser.add_argument("--gps", action="store_true",
                        help="use GPS data in modelling")
    args = parser.parse_args()
    os.chdir(args.folder)
    used_data = []
    used_data = used_data + ['gps'] if args.gps else used_data
    used_data = used_data + ['strong_motion'] if args.strong else used_data
    used_data = used_data + ['cgps'] if args.cgps else used_data
    used_data = used_data + ['tele_body'] if args.tele else used_data
    used_data = used_data + ['surf_tele'] if args.surface else used_data
    if args.gcmt_tensor:
        cmt_file = args.gcmt_tensor
        tensor_info = tensor.get_tensor(cmt_file=cmt_file)
    else:
        tensor_info = tensor.get_tensor()
    segments_data = json.load(open('segments_data.json'))
    segments = segments_data['segments']
    if not os.path.isfile('velmodel_data.json'):
        raise FileNotFoundError(
            errno.ENOENT, os.strerror(errno.ENOENT), 'velmodel_data.json')
    vel_model = json.load(open('velmodel_data.json'))
    solution = get_outputs.read_solution_static_format(segments)
    static_to_fsp(tensor_info, segments_data, used_data, vel_model, solution)

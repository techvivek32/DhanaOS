/// The eleven steps of intake, as one model.
///
/// The mockups' own numbering contradicted itself throughout — `capture_details` called itself
/// "Step 2 of 5", `quick_specs` called itself "Step 3 of 8", and `review_job_order` was "Step 6".
/// Three different denominators for one flow. D-012 settles the sequence; this enum is the single
/// place it is written down, so no screen can print a number that disagrees with the rail.
///
/// [created] is a step in the sequence because the operator experiences it as one — it is where
/// the minted `DH-<year>-<seq>` appears and where CAD gets assigned. It simply has no form and no
/// gate.
library;

import 'package:flutter/material.dart';

enum IntakeStep {
  jobType(
    number: 1,
    shortLabel: 'Job Type',
    title: 'What are we making?',
    subtitle: 'The kind of work decides which questions come next.',
    icon: Icons.category_outlined,
  ),
  media(
    number: 2,
    shortLabel: 'References',
    title: 'Capture the brief',
    subtitle: 'A photo, a voice note or a sketch. Any one of the three is enough.',
    icon: Icons.photo_camera_outlined,
  ),
  category(
    number: 3,
    shortLabel: 'Category',
    title: 'Which piece?',
    subtitle: 'The category first, then the style the customer asked for.',
    icon: Icons.diamond_outlined,
  ),
  design(
    number: 4,
    shortLabel: 'Design',
    title: 'Design specification',
    subtitle: 'How it is built, and how it has to fit.',
    icon: Icons.architecture_outlined,
  ),
  metal(
    number: 5,
    shortLabel: 'Metal',
    title: 'Metal & materials',
    subtitle: 'What it is made of, and what it has to weigh.',
    icon: Icons.layers_outlined,
  ),
  stones(
    number: 6,
    shortLabel: 'Stones',
    title: 'Stones',
    subtitle: 'Centre stone, side stones and melee — origin always stated.',
    icon: Icons.brightness_high_outlined,
  ),
  commercials(
    number: 7,
    shortLabel: 'Pricing',
    title: 'Pricing',
    subtitle: 'What this costs to build, and what it is sold at.',
    icon: Icons.request_quote_outlined,
  ),
  delivery(
    number: 8,
    shortLabel: 'Delivery',
    title: 'Delivery',
    subtitle: 'When the customer needs it, and what the plan actually allows.',
    icon: Icons.local_shipping_outlined,
  ),
  quality(
    number: 9,
    shortLabel: 'Quality',
    title: 'Quality acceptance',
    subtitle: 'What QC will measure the finished piece against.',
    icon: Icons.fact_check_outlined,
  ),
  review(
    number: 10,
    shortLabel: 'Review',
    title: 'Review the job order',
    subtitle: 'Everything captured, before this becomes a live job.',
    icon: Icons.checklist_rtl_outlined,
  ),
  created(
    number: 11,
    shortLabel: 'Created',
    title: 'Job order created',
    subtitle: 'The specification is locked in and routed to CAD.',
    icon: Icons.verified_outlined,
  );

  const IntakeStep({
    required this.number,
    required this.shortLabel,
    required this.title,
    required this.subtitle,
    required this.icon,
  });

  /// 1-based, and the same number `jobs.wizard_step` stores.
  final int number;

  /// Two words at most. Used in the CTA — "Continue to Metal" — and in the review's edit links.
  final String shortLabel;

  /// The question the step asks, in the operator's words.
  final String title;
  final String subtitle;
  final IconData icon;

  static const total = 11;

  /// Everything except the confirmation screen: the steps that take input and can be gated.
  static const form = <IntakeStep>[
    jobType, media, category, design, metal, stones,
    commercials, delivery, quality, review,
  ];

  bool get isForm => this != created;

  /// Resolves `jobs.wizard_step` and the `/jobs/new/step/:n` path parameter. Out-of-range values
  /// land on step one rather than crashing a resumed draft.
  static IntakeStep fromNumber(int? n) {
    for (final step in values) {
      if (step.number == n) return step;
    }
    return jobType;
  }
}

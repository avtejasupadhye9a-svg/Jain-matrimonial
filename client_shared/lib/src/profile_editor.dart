// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import 'api.dart';
import 'presentation.dart';

typedef Field = ({String key, String label});
const basics = <Field>[
  (key: 'name', label: 'Full name'),
  (key: 'dob', label: 'Birth date (YYYY-MM-DD)'),
  (key: 'gender', label: 'Gender'),
  (key: 'heightCm', label: 'Height (cm)'),
  (key: 'maritalStatus', label: 'Marital status'),
  (key: 'motherTongue', label: 'Mother tongue'),
  (key: 'country', label: 'Country'),
  (key: 'state', label: 'State or region'),
  (key: 'district', label: 'District'),
  (key: 'city', label: 'City'),
  (key: 'hometown', label: 'Hometown'),
  (key: 'biography', label: 'About you'),
];
const community = <Field>[
  (key: 'tradition', label: 'Jain tradition'),
  (key: 'subCommunity', label: 'Sub-community'),
  (key: 'customs', label: 'Customs'),
  (key: 'religiousPractice', label: 'Religious practices'),
];
const professional = <Field>[
  (key: 'qualification', label: 'Highest qualification'),
  (key: 'degree', label: 'Degree'),
  (key: 'specialization', label: 'Specialization'),
  (key: 'institution', label: 'Institution'),
  (key: 'occupation', label: 'Occupation'),
  (key: 'jobBusiness', label: 'Job or business'),
  (key: 'employmentType', label: 'Employment type'),
  (key: 'employer', label: 'Employer or business name'),
  (key: 'workLocation', label: 'Work location'),
  (key: 'incomeBand', label: 'Income band'),
];
const family = <Field>[
  (key: 'parentsGuardians', label: 'Parents or guardians'),
  (key: 'familyType', label: 'Family type'),
  (key: 'siblings', label: 'Siblings'),
  (key: 'familyLocation', label: 'Family location'),
  (key: 'familyIntroduction', label: 'Family introduction'),
  (key: 'diet', label: 'Diet'),
  (key: 'languages', label: 'Languages, separated by commas'),
  (key: 'hobbies', label: 'Hobbies'),
  (key: 'interests', label: 'Personal interests'),
  (key: 'relocate', label: 'Willing to relocate'),
];
const preferenceFields = <Field>[
  (key: 'minAge', label: 'Minimum age'),
  (key: 'maxAge', label: 'Maximum age'),
  (key: 'minHeight', label: 'Minimum height (cm)'),
  (key: 'maxHeight', label: 'Maximum height (cm)'),
  (key: 'maritalStatus', label: 'Marital status'),
  (key: 'country', label: 'Country'),
  (key: 'state', label: 'State or region'),
  (key: 'city', label: 'City'),
  (key: 'qualification', label: 'Education'),
  (key: 'occupation', label: 'Occupation'),
  (key: 'diet', label: 'Diet'),
  (key: 'tradition', label: 'Jain tradition'),
  (key: 'subCommunity', label: 'Sub-community'),
];
const searchFields = <Field>[
  (key: 'id', label: 'Profile ID'),
  ...preferenceFields,
  (key: 'district', label: 'District'),
  (key: 'degree', label: 'Degree'),
  (key: 'employmentType', label: 'Employment type'),
  (key: 'incomeBand', label: 'Income band'),
  (key: 'language', label: 'Language'),
  (key: 'relocate', label: 'Willing to relocate'),
  (key: 'sort', label: 'Sort order'),
];
const sectionNames = [
  'Basics',
  'Jain background',
  'Education and career',
  'Family and lifestyle',
  'Partner preferences',
];
const sections = [basics, community, professional, family, preferenceFields];
const controls = {
  'gender': ['woman', 'man', 'another_identity', 'prefer_not_to_say'],
  'maritalStatus': ['never_married', 'divorced', 'widowed', 'separated'],
  'employmentType': [
    'employed',
    'self_employed',
    'student',
    'not_employed',
    'retired',
    'other',
  ],
  'relocate': ['true', 'false'],
  'sort': ['recent', 'age_asc', 'age_desc'],
};
const numeric = {'heightCm', 'minHeight', 'maxHeight', 'minAge', 'maxAge'};

class FieldInputs extends StatelessWidget {
  const FieldInputs({
    super.key,
    required this.fields,
    required this.values,
    required this.update,
    this.errors = const {},
    this.requiredKeys = const {},
    this.enabled = true,
  });
  final List<Field> fields;
  final Json values;
  final void Function(String, Object?) update;
  final Json errors;
  final Set<String> requiredKeys;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Column(
    children: fields.map((field) {
      final value = values[field.key];
      final options = controls[field.key];
      final decoration = InputDecoration(
        labelText: requiredKeys.contains(field.key)
            ? '${field.label} *'
            : field.label,
        errorText: errors[field.key]?.toString(),
      );
      final child = options != null
          ? DropdownButtonFormField<String>(
              initialValue: options.contains(value?.toString())
                  ? value.toString()
                  : '',
              decoration: decoration,
              items: [
                const DropdownMenuItem(value: '', child: Text('Choose…')),
                ...options.map(
                  (option) => DropdownMenuItem(
                    value: option,
                    child: Text(label(option)),
                  ),
                ),
              ],
              onChanged: !enabled
                  ? null
                  : (next) {
                      if (next == null || next.isEmpty) {
                        update(field.key, null);
                      } else {
                        update(
                          field.key,
                          field.key == 'relocate' ? next == 'true' : next,
                        );
                      }
                    },
            )
          : TextFormField(
              enabled: enabled,
              minLines:
                  const {
                    'biography',
                    'familyIntroduction',
                    'customs',
                  }.contains(field.key)
                  ? 3
                  : 1,
              maxLines:
                  const {
                    'biography',
                    'familyIntroduction',
                    'customs',
                  }.contains(field.key)
                  ? 6
                  : 1,
              initialValue: value is List
                  ? value.join(', ')
                  : value?.toString(),
              decoration: decoration,
              keyboardType: numeric.contains(field.key)
                  ? TextInputType.number
                  : TextInputType.text,
              onChanged: !enabled
                  ? null
                  : (next) {
                      final text = next.trim();
                      if (text.isEmpty) {
                        update(field.key, null);
                      } else if (field.key == 'languages') {
                        update(
                          field.key,
                          text
                              .split(',')
                              .map((word) => word.trim())
                              .where((word) => word.isNotEmpty)
                              .toList(),
                        );
                      } else {
                        update(
                          field.key,
                          numeric.contains(field.key)
                              ? int.tryParse(text) ?? text
                              : text,
                        );
                      }
                    },
            );
      return Padding(padding: const EdgeInsets.only(bottom: 12), child: child);
    }).toList(),
  );
}

class ProfileEditor extends StatefulWidget {
  const ProfileEditor({
    super.key,
    required this.api,
    this.draft,
    this.admin = false,
  });
  final Api api;
  final Draft? draft;
  final bool admin;

  @override
  State<ProfileEditor> createState() => _ProfileEditorState();
}

class _ProfileEditorState extends State<ProfileEditor> {
  late Json data = Map.of(widget.draft?.data ?? {});
  late Json preferences = data['preferences'] is Map
      ? asJson(data['preferences'])
      : {};
  String? id;
  int? version;
  int step = 0;
  bool agreed = false;
  bool busy = false;
  String claimEmail = '';
  String evidence = '';
  Json errors = {};
  String? problem;

  static const requiredProfile = {
    'name',
    'dob',
    'gender',
    'country',
    'city',
    'tradition',
  };

  void showError(String message, Json fields) {
    if (!mounted) return;
    final earlier = sections.indexWhere(
      (fieldsInSection) =>
          fieldsInSection.any((field) => fields.containsKey(field.key)),
    );
    setState(() {
      problem = message;
      errors = fields;
      if (earlier >= 0) step = earlier;
    });
  }

  @override
  void initState() {
    super.initState();
    id = widget.draft?.id;
    version = widget.draft?.version;
  }

  Future<void> save(bool submit) async {
    if (busy) return;
    final missing = <String, dynamic>{
      for (final key in requiredProfile)
        if (submit && !data.containsKey(key)) key: 'Required to submit.',
      if (id == null && !agreed)
        'consent': 'Confirm authorization before saving.',
      if (id == null &&
          widget.admin &&
          !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(claimEmail.trim()))
        'claimEmail': 'Enter a valid email.',
      if (id == null && widget.admin && evidence.trim().length < 12)
        'consentEvidence': 'Enter at least 12 characters.',
    };
    if (missing.isNotEmpty) {
      showError('Review the highlighted fields.', missing);
      return;
    }
    if (submit &&
        !await confirm(
          context,
          'Submit for review?',
          'Administrators will review this version before publication.',
        ))
      return;
    if (!mounted) return;
    setState(() {
      busy = true;
      problem = null;
      errors = {};
    });
    try {
      data['preferences'] = preferences;
      final current = id;
      final result = current == null
          ? await widget.api.post(
              widget.admin ? '/admin/profiles' : '/profiles',
              {
                'data': data,
                'consent': agreed,
                if (widget.admin) ...{
                  'claimEmail': claimEmail,
                  'consentEvidence': evidence,
                },
              },
            )
          : await widget.api.put('/profiles/$current', {
              'version': version,
              'data': data,
            });
      id = result['id'] as String;
      version = result['version'] as int;
      if (submit)
        await widget.api.post('/profiles/$id/submit', {'version': version});
      if (!mounted) return;
      if (submit) {
        Navigator.pop(context, true);
      } else {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Draft saved')));
      }
    } on ApiError catch (error) {
      showError(error.message, error.fields);
    } catch (_) {
      showError('The profile could not be saved. Try again.', {});
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(id == null ? 'Create a profile' : 'Edit profile'),
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 660),
        child: ListView(
          key: ValueKey(step),
          padding: const EdgeInsets.all(20),
          children: [
            LinearProgressIndicator(
              value: (step + 1) / sections.length,
              semanticsLabel:
                  'Profile section ${step + 1} of ${sections.length}',
            ),
            const SizedBox(height: 16),
            Text(
              sectionNames[step],
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 12),
            if (problem != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  problem!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            FieldInputs(
              key: ValueKey(step),
              fields: sections[step],
              requiredKeys: requiredProfile,
              errors: errors,
              enabled: !busy,
              values: step == 4 ? preferences : data,
              update: (key, value) {
                final destination = step == 4 ? preferences : data;
                if (value == null) {
                  destination.remove(key);
                } else {
                  destination[key] = value;
                }
              },
            ),
            if (id == null) ...[
              if (widget.admin) ...[
                TextFormField(
                  initialValue: claimEmail,
                  enabled: !busy,
                  keyboardType: TextInputType.emailAddress,
                  onChanged: (value) => claimEmail = value,
                  decoration: InputDecoration(
                    labelText: 'Candidate’s verified claim email',
                    errorText: errors['claimEmail']?.toString(),
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  initialValue: evidence,
                  enabled: !busy,
                  onChanged: (value) => evidence = value,
                  decoration: InputDecoration(
                    labelText: 'Consent evidence or reference',
                    errorText: errors['consentEvidence']?.toString(),
                  ),
                ),
              ],
              CheckboxListTile(
                value: agreed,
                onChanged: busy
                    ? null
                    : (next) => setState(() => agreed = next ?? false),
                subtitle: errors['consent'] is String
                    ? Text(errors['consent'] as String)
                    : null,
                title: Text(
                  widget.admin
                      ? 'The candidate explicitly authorized this profile.'
                      : 'I authorize creation and review of this profile.',
                ),
              ),
            ],
            if (step == 4)
              const ListTile(
                leading: Icon(Icons.photo_outlined),
                title: Text('Photo and document uploads are unavailable.'),
              ),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                if (step > 0)
                  OutlinedButton(
                    onPressed: busy ? null : () => setState(() => step--),
                    child: const Text('Back'),
                  ),
                if (step < 4)
                  FilledButton(
                    onPressed: busy ? null : () => setState(() => step++),
                    child: const Text('Next section'),
                  ),
                OutlinedButton(
                  onPressed: busy ? null : () => save(false),
                  child: const Text('Save draft'),
                ),
                if (step == 4)
                  FilledButton(
                    onPressed: busy ? null : () => save(true),
                    child: const Text('Submit for review'),
                  ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

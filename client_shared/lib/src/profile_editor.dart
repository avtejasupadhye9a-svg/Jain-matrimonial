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
  });
  final List<Field> fields;
  final Json values;
  final void Function(String, Object?) update;

  @override
  Widget build(BuildContext context) => Column(
    children: fields.map((field) {
      final value = values[field.key];
      final options = controls[field.key];
      final child = options != null
          ? DropdownButtonFormField<String>(
              initialValue: options.contains(value?.toString())
                  ? value.toString()
                  : '',
              decoration: InputDecoration(labelText: field.label),
              items: [
                const DropdownMenuItem(value: '', child: Text('Choose…')),
                ...options.map(
                  (option) => DropdownMenuItem(
                    value: option,
                    child: Text(label(option)),
                  ),
                ),
              ],
              onChanged: (next) {
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
              initialValue: value is List
                  ? value.join(', ')
                  : value?.toString(),
              decoration: InputDecoration(labelText: field.label),
              keyboardType: numeric.contains(field.key)
                  ? TextInputType.number
                  : TextInputType.text,
              onChanged: (next) {
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

  @override
  void initState() {
    super.initState();
    id = widget.draft?.id;
    version = widget.draft?.version;
  }

  Future<void> save(bool submit) async {
    if (busy) return;
    if (submit &&
        !await confirm(
          context,
          'Submit for review?',
          'Administrators will review this version before publication.',
        ))
      return;
    if (!mounted) return;
    setState(() => busy = true);
    await runAction(context, () async {
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
      if (mounted && submit) Navigator.pop(context, true);
    }, success: submit ? 'Submitted for review' : 'Draft saved');
    if (mounted) setState(() => busy = false);
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
            FieldInputs(
              key: ValueKey(step),
              fields: sections[step],
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
                  onChanged: (value) => claimEmail = value,
                  decoration: const InputDecoration(
                    labelText: 'Candidate’s verified claim email',
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  initialValue: evidence,
                  onChanged: (value) => evidence = value,
                  decoration: const InputDecoration(
                    labelText: 'Consent evidence or reference',
                  ),
                ),
              ],
              CheckboxListTile(
                value: agreed,
                onChanged: (next) => setState(() => agreed = next ?? false),
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

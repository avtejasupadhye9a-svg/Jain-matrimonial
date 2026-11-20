import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest
import uuid
from unittest.mock import patch

if os.name == "nt":
    from local_storage_service import managed


@unittest.skipUnless(os.name == "nt", "Windows backup")
class BackupTests(unittest.TestCase):
    def test_private_storage_rejects_untrusted_owner_reader_and_link(self):
        security = managed.win32security
        cases = (
            (managed.PRIVATE_SDDL, True),
            ("O:BUD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)", False),
            ("O:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;GR;;;BU)", False),
        )
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "private-object"
            path.write_bytes(b"fixture")
            for descriptor, trusted in cases:
                sd = security.ConvertStringSecurityDescriptorToSecurityDescriptor(descriptor, 1)
                with self.subTest(descriptor=descriptor), patch.object(security, "GetNamedSecurityInfo", return_value=sd):
                    if trusted:
                        managed.check_private(path)
                    else:
                        with self.assertRaises(ValueError):
                            managed.check_private(path)
            descriptor = security.ConvertStringSecurityDescriptorToSecurityDescriptor(managed.PRIVATE_SDDL, 1)
            os.link(path, Path(temp) / "second-link")
            with patch.object(security, "GetNamedSecurityInfo", return_value=descriptor):
                with self.assertRaises(ValueError):
                    managed.check_private(path)

    def test_resumable_copy_receipt_manifest_and_conflict_safe_restore(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)
            source=root/"source"
            target=root/"restore"
            for location in (source,target):
                for group in ("Photos","Documents","Pending","Quarantine"):
                    (location/group).mkdir(parents=True)
            name=str(uuid.uuid4()); origin=str(uuid.uuid4()); content=b"storage fixture"; digest=hashlib.sha256(content).hexdigest()
            (source/"Documents"/name).write_bytes(content)
            def metadata(kind,arg):
                if kind=="files":return {"items":[{"id":name,"state":"confirmed","sha256":digest}]}
                if kind=="receipts":return {"items":[{"ticket":str(uuid.uuid4()),"sha256":digest}]}
                return {"recorded":True}
            backup=root/"backup"
            with patch.object(managed,"private_dir",side_effect=lambda p:p.mkdir(exist_ok=True)),patch.object(managed,"info",return_value={"origin":origin}),patch.object(managed,"update"):
                with patch.object(managed,"cloud_backup",side_effect=ConnectionError):
                    with self.assertRaises(ConnectionError):managed.snapshot(backup,source)
                with patch.object(managed,"cloud_backup",side_effect=metadata) as cloud:
                    managed.snapshot(backup,source)
                    checkpoint=managed.checksum(backup/"manifest.json")
                    cloud.assert_called_with("confirm",checkpoint)
                managed.restore(backup,target,checkpoint)
                managed.restore(backup,target,checkpoint)
                self.assertEqual((target/"Documents"/name).read_bytes(),content)
                (target/"Documents"/name).write_bytes(b"preserve")
                with self.assertRaises(ValueError):managed.restore(backup,target,checkpoint)
                self.assertEqual((target/"Documents"/name).read_bytes(),b"preserve")
                (backup/"receipts.jsonl").write_text("damaged")
                with self.assertRaises(ValueError):managed.restore(backup,target,checkpoint)
                manifest=json.loads((backup/"manifest.json").read_bytes());manifest["files"]=[]
                (backup/"manifest.json").write_text(json.dumps(manifest))
                with self.assertRaises(ValueError):managed.restore(backup,target,checkpoint)

